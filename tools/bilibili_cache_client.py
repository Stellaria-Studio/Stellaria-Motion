#!/usr/bin/env python3
import argparse
import hashlib
import html
import json
import re
import shutil
import subprocess
import sys
import time
import uuid
import urllib.parse
import urllib.request
import http.cookiejar
from pathlib import Path


UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
)


def cookie_header(cookie_file):
    if not cookie_file:
        return ""
    path = Path(cookie_file).expanduser()
    if not path.exists():
        raise RuntimeError(f"Cookie 文件不存在：{path}")
    pairs = []
    raw = path.read_text(encoding="utf-8", errors="ignore")
    for line in raw.splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        if text.lower().startswith("cookie:"):
            return text.split(":", 1)[1].strip()
        if "\t" in text:
            parts = text.split("\t")
            if len(parts) >= 7:
                pairs.append(f"{parts[-2]}={parts[-1]}")
        elif "=" in text and ";" in text:
            return text
    return "; ".join(pairs)


def ambient_cookie(cookie):
    if cookie:
        return cookie
    now = int(time.time())
    token = uuid.uuid4().hex.upper()
    return f"buvid3={token}; b_nut={now}; CURRENT_FNVAL=16"


def fetch_json_with_headers(url, referer, cookie=""):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Referer": referer,
            "Accept": "application/json,text/plain,*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Origin": "https://www.bilibili.com",
            "Connection": "keep-alive",
            "Cookie": ambient_cookie(cookie),
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8")), resp.headers


def fetch_json(url, referer, cookie=""):
    payload, _headers = fetch_json_with_headers(url, referer, cookie)
    return payload


def csrf_token(cookie):
    match = re.search(r"(?:^|;\s*)bili_jct=([^;]+)", cookie or "")
    return urllib.parse.unquote(match.group(1)) if match else ""


def post_json(url, referer, cookie, data):
    token = csrf_token(cookie)
    if not cookie or not token:
        raise RuntimeError("需要先扫码登录后才能执行账号操作")
    payload = dict(data)
    payload["csrf"] = token
    encoded = urllib.parse.urlencode(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=encoded,
        headers={
            "User-Agent": UA,
            "Referer": referer,
            "Origin": "https://www.bilibili.com",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Accept": "application/json,text/plain,*/*",
            "Cookie": cookie,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def cookie_pairs_from_headers(headers):
    pairs = []
    for item in headers.get_all("Set-Cookie") or []:
        pair = item.split(";", 1)[0].strip()
        if "=" in pair:
            pairs.append(pair)
    return pairs


def cookie_pairs_from_login_url(url):
    if not url:
        return []
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Referer": "https://passport.bilibili.com/",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        },
    )
    try:
        opener.open(req, timeout=20).read(1024)
    except Exception:
        pass
    return [f"{cookie.name}={cookie.value}" for cookie in jar if cookie.name and cookie.value]


def bvid_from_url(url):
    match = re.search(r"(BV[0-9A-Za-z]+)", url)
    if match:
        return match.group(1)
    parsed = urllib.parse.urlparse(url)
    parts = [part for part in parsed.path.split("/") if part]
    for part in parts:
        if part.startswith("BV"):
            return part
    return ""


def bangumi_ref_from_url(url):
    match = re.search(r"/bangumi/play/(ss|ep)(\d+)", url)
    if match:
        return match.group(1), match.group(2)
    match = re.search(r"\b(ss|ep)(\d+)\b", url)
    if match:
        return match.group(1), match.group(2)
    return "", ""


def page_number_from_url(url):
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    try:
        return max(1, int((query.get("p") or ["1"])[0]))
    except Exception:
        return 1


def safe_name(value):
    cleaned = re.sub(r"[\\/:*?\"<>|\\s]+", "_", value).strip("._")
    return cleaned[:96] or "bilibili_video"


def pick_video(dash, max_height):
    videos = list(dash.get("video") or [])
    if not videos:
        return None
    preferred = []
    for video in videos:
        height = int(video.get("height") or 0)
        if height <= max_height:
            preferred.append(video)
    pool = preferred or videos
    # Prefer AVC for maximum AVFoundation compatibility, then higher resolution/bitrate.
    def score(item):
        codecs = str(item.get("codecs") or "").lower()
        avc_bonus = 10_000_000 if codecs.startswith("avc") else 0
        return avc_bonus + int(item.get("height") or 0) * 10_000 + int(item.get("bandwidth") or 0)
    return sorted(pool, key=score, reverse=True)[0]


def pick_audio(dash):
    audios = list(dash.get("audio") or [])
    if not audios:
        return None
    return sorted(audios, key=lambda item: int(item.get("bandwidth") or 0), reverse=True)[0]


def stream_url(item):
    urls = [item.get("baseUrl") or item.get("base_url")]
    urls.extend(item.get("backupUrl") or item.get("backup_url") or [])
    return next((url for url in urls if isinstance(url, str) and url.startswith("http")), "")


def video_url(bvid):
    return f"https://www.bilibili.com/video/{bvid}/"


def bangumi_url(season_id="", ep_id=""):
    if ep_id:
        return f"https://www.bilibili.com/bangumi/play/ep{ep_id}"
    if season_id:
        return f"https://www.bilibili.com/bangumi/play/ss{season_id}"
    return ""


def normalize_card(item):
    bvid = str(item.get("bvid") or item.get("aid") or "")
    if not bvid.startswith("BV"):
        arcurl = str(item.get("arcurl") or item.get("url") or "")
        bvid = bvid_from_url(arcurl)
    title = re.sub(r"<[^>]+>", "", str(item.get("title") or ""))
    author = str(item.get("owner", {}).get("name") if isinstance(item.get("owner"), dict) else item.get("author") or item.get("name") or "")
    pic = str(item.get("pic") or "")
    if pic.startswith("//"):
        pic = "https:" + pic
    return {
        "title": title,
        "bvid": bvid,
        "url": video_url(bvid) if bvid else str(item.get("arcurl") or item.get("url") or ""),
        "author": author,
        "duration": str(item.get("duration") or ""),
        "play": int(item.get("stat", {}).get("view") if isinstance(item.get("stat"), dict) else item.get("play") or 0),
        "pic": pic,
        "kind": "video",
    }


def normalize_favorite_resource(item):
    upper = item.get("upper") if isinstance(item.get("upper"), dict) else {}
    cover = str(item.get("cover") or "")
    if cover.startswith("//"):
        cover = "https:" + cover
    bvid = str(item.get("bvid") or "")
    return {
        "title": str(item.get("title") or bvid or "收藏视频"),
        "bvid": bvid,
        "url": video_url(bvid) if bvid else str(item.get("link") or ""),
        "author": str(upper.get("name") or "收藏夹"),
        "duration": str(item.get("duration") or ""),
        "play": int(item.get("cnt_info", {}).get("play") if isinstance(item.get("cnt_info"), dict) else 0),
        "pic": cover,
        "kind": "video",
    }


def normalize_media_card(item):
    title = re.sub(r"<[^>]+>", "", str(item.get("title") or item.get("season_title") or ""))
    cover = str(item.get("cover") or item.get("pic") or "")
    if cover.startswith("//"):
        cover = "https:" + cover
    season_id = str(item.get("season_id") or "")
    ep_id = str(item.get("eps", [{}])[0].get("id") if isinstance(item.get("eps"), list) and item.get("eps") else "")
    url = str(item.get("url") or item.get("goto_url") or "") or bangumi_url(season_id, ep_id)
    if url.startswith("//"):
        url = "https:" + url
    return {
        "title": title,
        "bvid": "",
        "url": url,
        "author": str(item.get("org_title") or item.get("areas") or item.get("styles") or "番剧/影视"),
        "duration": str(item.get("index_show") or item.get("pubtime") or ""),
        "play": int(item.get("media_score", {}).get("user_count") if isinstance(item.get("media_score"), dict) else 0),
        "pic": cover,
        "kind": "bangumi",
        "season_id": season_id,
        "ep_id": ep_id,
    }


def normalize_episode(episode):
    ep_id = str(episode.get("id") or "")
    title = str(episode.get("long_title") or episode.get("title") or episode.get("index") or ep_id)
    return {
        "title": title,
        "url": bangumi_url("", ep_id) if ep_id else "",
        "duration": str(episode.get("duration") or ""),
    }


def account_mid(cookie):
    nav = fetch_json("https://api.bilibili.com/x/web-interface/nav", "https://www.bilibili.com/", cookie)
    if int(nav.get("code") or 0) != 0:
        raise RuntimeError(str(nav.get("message") or "B 站账号状态获取失败"))
    mid = str((nav.get("data") or {}).get("mid") or "")
    if not mid or mid == "0":
        raise RuntimeError("未登录 B 站账号")
    return mid


def favorite_folders(cookie):
    mid = account_mid(cookie)
    params = urllib.parse.urlencode({"up_mid": mid, "type": 2})
    payload = fetch_json(f"https://api.bilibili.com/x/v3/fav/folder/created/list-all?{params}", "https://space.bilibili.com/", cookie)
    if int(payload.get("code") or 0) != 0:
        raise RuntimeError(str(payload.get("message") or "B 站收藏夹 API 失败"))
    return (payload.get("data") or {}).get("list") or []


def favorites(cookie, limit):
    folders = favorite_folders(cookie)
    if not folders:
        return []
    media_id = str(folders[0].get("id") or "")
    params = urllib.parse.urlencode({
        "media_id": media_id,
        "pn": 1,
        "ps": max(1, min(50, limit)),
        "keyword": "",
        "order": "mtime",
        "type": 0,
        "tid": 0,
        "platform": "web",
    })
    payload = fetch_json(f"https://api.bilibili.com/x/v3/fav/resource/list?{params}", "https://space.bilibili.com/", cookie)
    if int(payload.get("code") or 0) != 0:
        raise RuntimeError(str(payload.get("message") or "B 站收藏列表 API 失败"))
    items = ((payload.get("data") or {}).get("medias") or [])[:max(1, min(50, limit))]
    return [card for item in items if (card := normalize_favorite_resource(item)).get("url")]


def home(cookie, limit, category="video"):
    referer = "https://www.bilibili.com/"
    capped = max(1, min(50, limit))
    if category == "bangumi":
        payload = fetch_json(
            f"https://api.bilibili.com/pgc/web/rank/list?season_type=1&day=3",
            referer,
            cookie,
        )
        if int(payload.get("code") or 0) != 0:
            raise RuntimeError(str(payload.get("message") or "B 站番剧推荐 API 失败"))
        items = (payload.get("result") or {}).get("list") or []
        return [card for item in items[:capped] if (card := normalize_media_card(item)).get("url")]
    if category == "film":
        payload = fetch_json(
            f"https://api.bilibili.com/pgc/web/rank/list?season_type=2&day=3",
            referer,
            cookie,
        )
        if int(payload.get("code") or 0) != 0:
            raise RuntimeError(str(payload.get("message") or "B 站影视推荐 API 失败"))
        items = (payload.get("result") or {}).get("list") or []
        return [card for item in items[:capped] if (card := normalize_media_card(item)).get("url")]
    payload = fetch_json(f"https://api.bilibili.com/x/web-interface/popular?ps={capped}&pn=1", referer, cookie)
    if int(payload.get("code") or 0) != 0:
        raise RuntimeError(str(payload.get("message") or "B 站热门 API 失败"))
    items = (payload.get("data") or {}).get("list") or []
    return [normalize_card(item) for item in items if normalize_card(item).get("bvid")]


def normalize_up_card(item):
    mid = str(item.get("mid") or "")
    name = re.sub(r"<[^>]+>", "", str(item.get("uname") or item.get("name") or ""))
    face = str(item.get("upic") or item.get("face") or "")
    if face.startswith("//"):
        face = "https:" + face
    fans = int(item.get("fans") or 0)
    videos = int(item.get("videos") or 0)
    return {
        "title": name or f"UP {mid}",
        "bvid": "",
        "url": f"https://space.bilibili.com/{mid}" if mid else "",
        "author": f"{fans} 粉丝",
        "duration": f"{videos} 投稿",
        "play": fans,
        "pic": face,
        "kind": "up",
        "mid": mid,
    }


def search(keyword, cookie, limit, category="video", order="totalrank"):
    referer = "https://search.bilibili.com/"
    search_type = {
        "video": "video",
        "bangumi": "media_bangumi",
        "film": "media_ft",
        "up": "bili_user",
    }.get(category, "video")
    params = urllib.parse.urlencode({
        "search_type": search_type,
        "keyword": keyword,
        "page": 1,
        "page_size": max(1, min(50, limit)),
        "order": order,
    })
    payload = fetch_json(f"https://api.bilibili.com/x/web-interface/search/type?{params}", referer, cookie)
    if int(payload.get("code") or 0) != 0:
        raise RuntimeError(str(payload.get("message") or "B 站搜索 API 失败"))
    items = (payload.get("data") or {}).get("result") or []
    if search_type == "video":
        return [card for item in items if (card := normalize_card(item)).get("bvid")]
    if search_type == "bili_user":
        return [card for item in items if (card := normalize_up_card(item)).get("url")]
    return [card for item in items if (card := normalize_media_card(item)).get("url")]


def resolve_view(url, cookie):
    bvid = bvid_from_url(url)
    if bvid:
        referer = f"https://www.bilibili.com/video/{bvid}/"
        view = fetch_json(f"https://api.bilibili.com/x/web-interface/view?bvid={urllib.parse.quote(bvid)}", referer, cookie)
        if int(view.get("code") or 0) != 0:
            raise RuntimeError(str(view.get("message") or "B 站 view API 失败"))
        data = view.get("data") or {}
        stat = data.get("stat") if isinstance(data.get("stat"), dict) else {}
        pages = data.get("pages") or []
        if not pages:
            raise RuntimeError("未找到视频分 P/cid")
        page_number = page_number_from_url(url)
        chosen_page = next((page for page in pages if int(page.get("page") or 0) == page_number), pages[0])
        cid = int(chosen_page.get("cid") or 0)
        if cid <= 0:
            raise RuntimeError("cid 无效")
        part = str(chosen_page.get("part") or "")
        title = str(data.get("title") or bvid)
        if len(pages) > 1 and part:
            title = f"{title}_{page_number}_{part}"
        return bvid, cid, title, referer

    ref_kind, ref_id = bangumi_ref_from_url(url)
    if ref_kind and ref_id:
        referer = "https://www.bilibili.com/bangumi/"
        query_key = "season_id" if ref_kind == "ss" else "ep_id"
        season = fetch_json(f"https://api.bilibili.com/pgc/view/web/season?{query_key}={urllib.parse.quote(ref_id)}", referer, cookie)
        if int(season.get("code") or 0) != 0:
            raise RuntimeError(str(season.get("message") or "B 站番剧 API 失败"))
        result = season.get("result") or {}
        episodes = result.get("episodes") or []
        chosen = None
        if ref_kind == "ep":
            chosen = next((episode for episode in episodes if str(episode.get("id") or "") == ref_id), None)
        chosen = chosen or (episodes[0] if episodes else None)
        if not chosen:
            raise RuntimeError("番剧条目没有可播放分集")
        bvid = str(chosen.get("bvid") or "")
        cid = int(chosen.get("cid") or 0)
        if not bvid or cid <= 0:
            raise RuntimeError("番剧分集缺少 bvid/cid")
        title = safe_name(f"{result.get('title') or 'bangumi'}_{chosen.get('title') or chosen.get('long_title') or ref_id}")
        ep_url = bangumi_url("", str(chosen.get("id") or ref_id))
        return bvid, cid, title, ep_url or referer

    raise RuntimeError("未识别到 BV 号或番剧分集")


def detail(url, cookie):
    bvid = bvid_from_url(url)
    if bvid:
        referer = video_url(bvid)
        view = fetch_json(f"https://api.bilibili.com/x/web-interface/view?bvid={urllib.parse.quote(bvid)}", referer, cookie)
        if int(view.get("code") or 0) != 0:
            raise RuntimeError(str(view.get("message") or "B 站 view API 失败"))
        data = view.get("data") or {}
        stat = data.get("stat") if isinstance(data.get("stat"), dict) else {}
        pages = data.get("pages") or []
        episodes = []
        for page in pages:
            page_num = int(page.get("page") or len(episodes) + 1)
            part = str(page.get("part") or f"P{page_num}")
            episodes.append({
                "title": f"P{page_num} {part}",
                "url": f"{video_url(bvid)}?p={page_num}",
                "duration": str(page.get("duration") or ""),
            })
        comments = []
        aid = data.get("aid")
        if aid:
            try:
                params = urllib.parse.urlencode({"type": 1, "oid": aid, "mode": 3, "ps": 8})
                replies = fetch_json(f"https://api.bilibili.com/x/v2/reply/main?{params}", referer, cookie)
                for reply in ((replies.get("data") or {}).get("replies") or []):
                    member = reply.get("member") or {}
                    content = reply.get("content") or {}
                    message = re.sub(r"\s+", " ", str(content.get("message") or "")).strip()
                    if message:
                        comments.append({
                            "user": str(member.get("uname") or "B站用户"),
                            "message": message[:180],
                        })
            except Exception:
                comments = []
        return {
            "ok": True,
            "title": str(data.get("title") or bvid),
            "url": video_url(bvid),
            "cover": str(data.get("pic") or ""),
            "desc": str(data.get("desc") or "暂无简介"),
            "episodes": episodes,
            "comments": comments,
            "stat": {
                "view": int(stat.get("view") or 0),
                "like": int(stat.get("like") or 0),
                "favorite": int(stat.get("favorite") or 0),
                "coin": int(stat.get("coin") or 0),
                "reply": int(stat.get("reply") or 0),
            },
            "bvid": bvid,
            "aid": str(data.get("aid") or ""),
            "kind": "video",
        }

    ref_kind, ref_id = bangumi_ref_from_url(url)
    if ref_kind and ref_id:
        referer = "https://www.bilibili.com/bangumi/"
        query_key = "season_id" if ref_kind == "ss" else "ep_id"
        season = fetch_json(f"https://api.bilibili.com/pgc/view/web/season?{query_key}={urllib.parse.quote(ref_id)}", referer, cookie)
        if int(season.get("code") or 0) != 0:
            raise RuntimeError(str(season.get("message") or "B 站番剧 API 失败"))
        result = season.get("result") or {}
        episodes = [episode for episode in (normalize_episode(ep) for ep in result.get("episodes") or []) if episode.get("url")]
        return {
            "ok": True,
            "title": str(result.get("title") or "番剧/影视"),
            "url": url,
            "cover": str(result.get("cover") or ""),
            "desc": str(result.get("evaluate") or result.get("new_ep", {}).get("desc") or "暂无简介"),
            "episodes": episodes,
            "comments": [],
            "stat": {},
            "bvid": "",
            "aid": "",
            "kind": "bangumi",
        }
    raise RuntimeError("未识别到可展示详情的 B 站链接")


def action(url, name, cookie):
    bvid = bvid_from_url(url)
    if not bvid:
        raise RuntimeError("账号操作目前仅支持 BV 视频")
    referer = video_url(bvid)
    view = fetch_json(f"https://api.bilibili.com/x/web-interface/view?bvid={urllib.parse.quote(bvid)}", referer, cookie)
    if int(view.get("code") or 0) != 0:
        raise RuntimeError(str(view.get("message") or "B 站 view API 失败"))
    data = view.get("data") or {}
    aid = str(data.get("aid") or "")
    if not aid:
        raise RuntimeError("未取得视频 aid")
    if name == "like":
        payload = post_json(
            "https://api.bilibili.com/x/web-interface/archive/like",
            referer,
            cookie,
            {"bvid": bvid, "like": 1},
        )
    elif name == "favorite":
        folders = favorite_folders(cookie)
        if not folders:
            raise RuntimeError("账号没有可用收藏夹")
        media_id = str(folders[0].get("id") or "")
        payload = post_json(
            "https://api.bilibili.com/x/v3/fav/resource/deal",
            referer,
            cookie,
            {"rid": aid, "type": 2, "add_media_ids": media_id, "del_media_ids": ""},
        )
    else:
        raise RuntimeError("未知账号操作")
    if int(payload.get("code") or 0) != 0:
        raise RuntimeError(str(payload.get("message") or "B 站账号操作失败"))
    return {"ok": True, "action": name, "bvid": bvid}


def run_ffmpeg(ffmpeg, inputs, output, referer):
    args = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-y"]
    for url in inputs:
        args.extend([
            "-headers",
            f"Referer: {referer}\r\nUser-Agent: {UA}\r\n",
            "-i",
            url,
        ])
    if len(inputs) == 1:
        args.extend(["-c", "copy", "-movflags", "+faststart", str(output)])
    else:
        args.extend(["-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-movflags", "+faststart", str(output)])
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "ffmpeg failed").strip())


def login_qrcode(output_dir, timeout=180):
    output_dir.mkdir(parents=True, exist_ok=True)
    referer = "https://passport.bilibili.com/"
    payload = fetch_json("https://passport.bilibili.com/x/passport-login/web/qrcode/generate", referer, "")
    if int(payload.get("code") or 0) != 0:
        raise RuntimeError(str(payload.get("message") or "B 站登录二维码生成失败"))
    data = payload.get("data") or {}
    login_url = str(data.get("url") or "")
    qrcode_key = str(data.get("qrcode_key") or "")
    if not login_url or not qrcode_key:
        raise RuntimeError("B 站登录二维码缺少 url/qrcode_key")
    qr_image = "https://api.qrserver.com/v1/create-qr-code/?" + urllib.parse.urlencode({
        "size": "280x280",
        "margin": "12",
        "data": login_url,
    })
    qr_page = output_dir / "bilibili_login_qr.html"
    qr_page_html = """<!doctype html>
<meta charset="utf-8">
<title>Stellaria Motion - Bilibili login</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#11151c;color:#edf3ff;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.card{width:360px;padding:28px;border:1px solid rgba(255,255,255,.16);border-radius:18px;background:#1a2029;box-shadow:0 24px 70px rgba(0,0,0,.45);text-align:center}
img{width:280px;height:280px;background:#fff;border-radius:12px;padding:10px}
h1{font-size:20px;margin:0 0 18px}
p{color:#aeb9c9;font-size:14px;line-height:1.6;margin:16px 0 0}
code{word-break:break-all;color:#c8ddff;font-size:11px}
</style>
<div class="card">
<h1>Bilibili 扫码登录</h1>
<img src="__QR_IMAGE__" alt="Bilibili login QR">
<p>请用哔哩哔哩手机 App 扫码确认。这个页面只显示二维码，不跳转手机软件下载页。</p>
<p><code>__LOGIN_URL__</code></p>
</div>
"""
    qr_page.write_text(
        qr_page_html
        .replace("__QR_IMAGE__", html.escape(qr_image, quote=True))
        .replace("__LOGIN_URL__", html.escape(login_url)),
        encoding="utf-8",
    )
    if sys.platform == "darwin":
        subprocess.Popen(["open", str(qr_page)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    deadline = time.time() + timeout
    last_message = "等待扫码"
    poll_url = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=" + urllib.parse.quote(qrcode_key)
    while time.time() < deadline:
        time.sleep(2.0)
        poll, headers = fetch_json_with_headers(poll_url, referer, "")
        data = poll.get("data") or {}
        raw_code = data.get("code") if "code" in data else poll.get("code", -1)
        code = int(raw_code)
        last_message = str(data.get("message") or poll.get("message") or last_message)
        if code == 0:
            pairs = cookie_pairs_from_headers(headers)
            login_redirect = str((poll.get("data") or {}).get("url") or "")
            if not pairs:
                pairs = cookie_pairs_from_login_url(login_redirect)
            if not pairs:
                raise RuntimeError("登录成功但未收到 Cookie")
            cookie_file = output_dir / "bilibili_login_cookie.txt"
            cookie_file.write_text("Cookie: " + "; ".join(pairs) + "\n", encoding="utf-8")
            return {
                "ok": True,
                "cookieFile": str(cookie_file),
                "message": "扫码登录完成",
                "loginURL": str(qr_page),
            }
        if code == 86038:
            raise RuntimeError("二维码已过期，请重新扫码登录")
    raise RuntimeError(f"扫码登录超时：{last_message}")


def resolve(url, output_dir, max_height, cookie=""):
    bvid, cid, resolved_title, referer = resolve_view(url, cookie)
    if max_height >= 2160:
        qn = 120
    elif max_height >= 1080:
        qn = 80
    elif max_height >= 720:
        qn = 64
    elif max_height >= 480:
        qn = 32
    else:
        qn = 16
    params = urllib.parse.urlencode({
        "bvid": bvid,
        "cid": cid,
        "qn": qn,
        "fnval": 16,
        "fourk": 1,
    })
    play = fetch_json(f"https://api.bilibili.com/x/player/playurl?{params}", referer, cookie)
    if int(play.get("code") or 0) != 0:
        raise RuntimeError(str(play.get("message") or "B 站 playurl API 失败"))
    play_data = play.get("data") or {}
    title = safe_name(resolved_title)
    key = hashlib.sha1(f"{bvid}:{cid}:{max_height}".encode("utf-8")).hexdigest()[:12]
    output = output_dir / f"{title}-{bvid}-{key}.mp4"
    if output.exists() and output.stat().st_size > 1024 * 1024:
        return {
            "ok": True,
            "cached": True,
            "path": str(output),
            "title": resolved_title,
            "bvid": bvid,
            "cid": cid,
            "quality": "cached",
        }

    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not Path(ffmpeg).exists():
        raise RuntimeError("未找到 ffmpeg，请先安装 Homebrew ffmpeg")
    output_dir.mkdir(parents=True, exist_ok=True)
    temp = output.with_suffix(f".{int(time.time())}.part.mp4")
    dash = play_data.get("dash") or {}
    video = pick_video(dash, max_height)
    audio = pick_audio(dash)
    if video:
        selected_height = int(video.get("height") or 0)
        selected_codecs = str(video.get("codecs") or "")
        video_url = stream_url(video)
        audio_url = stream_url(audio) if audio else ""
        if not video_url:
            raise RuntimeError("B 站 DASH 视频地址为空")
        inputs = [video_url] + ([audio_url] if audio_url else [])
        run_ffmpeg(ffmpeg, inputs, temp, referer)
    else:
        selected_height = int(play_data.get("quality") or 0)
        selected_codecs = "durl"
        durl = play_data.get("durl") or []
        first = durl[0] if durl else {}
        direct = first.get("url") or ""
        if not direct:
            raise RuntimeError("B 站 playurl 未返回可播放地址")
        run_ffmpeg(ffmpeg, [direct], temp, referer)
    temp.replace(output)
    return {
        "ok": True,
        "cached": False,
        "path": str(output),
        "title": resolved_title,
        "bvid": bvid,
        "cid": cid,
        "quality": {
            "height": selected_height,
            "codecs": selected_codecs,
            "maxHeight": max_height,
            "loginCookie": bool(cookie),
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Resolve/search/cache Bilibili videos as local MP4 files for Stellaria Motion.")
    parser.add_argument("--mode", choices=["cache", "home", "search", "login", "detail", "favorites", "action"], default="cache")
    parser.add_argument("--url")
    parser.add_argument("--keyword")
    parser.add_argument("--action", choices=["like", "favorite"], default="like")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--max-height", type=int, default=1080)
    parser.add_argument("--cookie-file", default="")
    parser.add_argument("--limit", type=int, default=24)
    parser.add_argument("--category", choices=["video", "up", "bangumi", "film"], default="video")
    parser.add_argument("--order", choices=["totalrank", "click", "pubdate", "dm", "stow"], default="totalrank")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        cookie = cookie_header(args.cookie_file)
        if args.mode == "home":
            result = {"ok": True, "items": home(cookie, args.limit, args.category)}
        elif args.mode == "search":
            if not args.keyword:
                raise RuntimeError("搜索关键词为空")
            result = {"ok": True, "items": search(args.keyword, cookie, args.limit, args.category, args.order)}
        elif args.mode == "login":
            result = login_qrcode(Path(args.output_dir).expanduser())
        elif args.mode == "detail":
            if not args.url:
                raise RuntimeError("详情链接为空")
            result = detail(args.url, cookie)
        elif args.mode == "favorites":
            result = {"ok": True, "items": favorites(cookie, args.limit)}
        elif args.mode == "action":
            if not args.url:
                raise RuntimeError("账号操作链接为空")
            result = action(args.url, args.action, cookie)
        else:
            if not args.url:
                raise RuntimeError("视频链接为空")
            result = resolve(args.url, Path(args.output_dir).expanduser(), max(240, args.max_height), cookie)
    except Exception as exc:
        result = {"ok": False, "error": str(exc)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
