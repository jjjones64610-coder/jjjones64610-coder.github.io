#!/usr/bin/env python3
"""Stream clipper: find the most entertaining moments on followed channels.

Twitch: viewer-made clips show where the moments are. For each strong one, the
matching window of the full broadcast (lead-up + moment + reaction) is
downloaded, Gemini picks exact clip boundaries in the streamer's style, and the
clip is cut and compressed to fit the Google Drive connector's upload limit.

YouTube: YouTube blocks video downloads from cloud machines, so Gemini watches
the stream by URL and the moments are reported as timestamp links.

The script never talks to Google Drive; the Claude session uploads what it
writes. Output: <out>/manifest.json plus the clip files it lists.
Standard library only (plus the yt-dlp and ffmpeg executables).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAX_UPLOAD_BYTES = 2_950_000          # connector carries about 3.1 MB of file per call
TARGET_BYTES = 2_750_000
LEAD_IN = 75                          # seconds of stream before the viewer clip starts
TAIL = 45                             # seconds after it ends (reaction)
HLS_FORMAT = '720p60/720p30/720p/best[height<=720]/best'


# ---------------------------------------------------------------- helpers

def log(msg: str) -> None:
    print(f'[clipper] {msg}', file=sys.stderr, flush=True)


def run(cmd: list[str], timeout: int = 300) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(f'{cmd[0]} failed: {(res.stderr or res.stdout).strip()[-400:]}')
    return res.stdout


def ytdlp_json(url: str, *extra: str, timeout: int = 180) -> dict:
    return json.loads(run(['yt-dlp', '-J', '--no-warnings', *extra, url], timeout=timeout))


def clean(text: str, limit: int = 70) -> str:
    text = re.sub(r'[\\/:*?"<>|\n\r\t]+', ' ', text or '').strip()
    text = re.sub(r'\s+', ' ', text)
    return text[:limit].rstrip() or 'clip'


def twitch_time(seconds: float) -> str:
    s = max(0, int(seconds))
    h, rest = divmod(s, 3600)
    m, sec = divmod(rest, 60)
    return f'{h}h{m}m{sec}s'


def clock(seconds: float) -> str:
    s = max(0, int(seconds))
    h, rest = divmod(s, 3600)
    m, sec = divmod(rest, 60)
    return f'{h}:{m:02d}:{sec:02d}' if h else f'{m}:{sec:02d}'


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def load_channels(path: Path) -> list[dict]:
    channels = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        ident, _, style = line.partition('|')
        platform, _, name = ident.strip().partition(':')
        if platform in ('twitch', 'youtube') and name:
            channels.append({'platform': platform, 'name': name.strip(), 'style': style.strip()})
    return channels


def load_seen(path: str | None) -> tuple[set[str], list[str]]:
    """IDs like tw-123 / yt-abc found in [brackets] in Drive file titles."""
    if not path or not Path(path).exists():
        return set(), []
    text = Path(path).read_text()
    return set(re.findall(r'\[((?:tw|yt)-[A-Za-z0-9_-]+)\]', text)), text.splitlines()


# ---------------------------------------------------------------- gemini (via the watch plugin)

def gemini_module():
    """Import gemini.py from the installed watch plugin, or a fresh clone of it."""
    candidates = sorted(glob.glob(os.path.expanduser(
        '~/.claude/plugins/cache/claude-video/watch/*/skills/watch/scripts/gemini.py')))
    if not candidates:
        dest = Path.home() / '.cache' / 'stream-clipper' / 'claude-video'
        if not dest.exists():
            run(['git', 'clone', '-q', '--depth', '1',
                 'https://github.com/bradautomates/claude-video.git', str(dest)], timeout=120)
        candidates = [str(dest / 'skills' / 'watch' / 'scripts' / 'gemini.py')]
    sys.path.insert(0, str(Path(candidates[-1]).parent))
    import gemini  # noqa: E402
    return gemini


def gemini_key() -> str | None:
    key = os.environ.get('GEMINI_API_KEY', '').strip()
    if key:
        return key
    env = Path.home() / '.config' / 'watch' / '.env'
    if env.exists():
        for line in env.read_text().splitlines():
            if line.strip().startswith('GEMINI_API_KEY='):
                value = line.split('=', 1)[1].strip().strip('"').strip("'")
                if value:
                    return value
    return None


_MODEL: str | None = None
_GEMINI_OFF: str | None = None   # set once Gemini is out of quota or down, so the run stops waiting on it
_TRANSIENT = ('Gemini network', 'Gemini service', 'Gemini quota')


def gemini_model() -> str:
    return _MODEL or os.environ.get('CLIPPER_GEMINI_MODEL') or os.environ.get('WATCH_GEMINI_MODEL') or 'gemini-3.7-flash'


def other_flash_models(gem, key: str) -> list[str]:
    """Other Flash models this key can use, newest first, for when the main one is overloaded."""
    try:
        _, _, body = gem._call('GET', f'{gem.API}/v1beta/models?pageSize=200', key, timeout=60)
        names = [m['name'].split('/', 1)[-1] for m in json.loads(body).get('models', [])
                 if 'generateContent' in (m.get('supportedGenerationMethods') or [])]
    except (SystemExit, Exception) as exc:  # noqa: BLE001
        log(f'could not list Gemini models ({str(exc).split(". Detail:")[0]})')
        return []
    flash = [n for n in names if 'flash' in n and not any(x in n for x in ('image', 'tts', 'audio', 'live', 'embedding'))
             and n != gemini_model()]
    return sorted(flash, reverse=True)[:3]


def ask_gemini(gem, key: str, video: dict, prompt: str, timeout: float, what: str) -> dict:
    """Ask the current model; if it stays busy or unreachable, try other Flash models once each.

    If none answers, Gemini is switched off for the rest of the run so later moments don't wait on it."""
    global _MODEL, _GEMINI_OFF
    if _GEMINI_OFF:
        raise SystemExit(f'Gemini skipped: {_GEMINI_OFF}')
    try:
        return with_retries(lambda: gem.ask(video, prompt, model=gemini_model(), key=key, timeout=timeout), what, 3)
    except SystemExit as exc:
        if not str(exc).startswith(_TRANSIENT):
            raise
        last = exc
    for model in other_flash_models(gem, key):
        log(f'{what}: {gemini_model()} unavailable; trying {model}')
        try:
            result = gem.ask(video, prompt, model=model, key=key, timeout=timeout)
            _MODEL = model  # stick with the model that answered for the rest of this run
            return result
        except SystemExit as exc:
            last = exc
    _GEMINI_OFF = str(last).split('. Detail:')[0]
    log(f'Gemini switched off for the rest of this run ({_GEMINI_OFF})')
    raise last


def with_retries(fn, what: str, attempts: int = 4):
    """Retry Gemini calls that fail from network drops or server errors."""
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except SystemExit as exc:
            text = str(exc)
            # Quota errors are not retried here: waiting rarely helps and it burns the run's time.
            transient = text.startswith(_TRANSIENT) and not text.startswith('Gemini quota')
            if not transient or attempt == attempts:
                raise
            wait = 30 * attempt
            log(f'{what}: {text.split(". Detail:")[0]}; retrying in {wait}s ({attempt}/{attempts - 1})')
            time.sleep(wait)


def parse_json(text: str):
    """Pull the first JSON object or array out of a model answer."""
    text = re.sub(r'```(?:json)?', '', text)
    for opener, closer in (('{', '}'), ('[', ']')):
        start = text.find(opener)
        end = text.rfind(closer)
        if start != -1 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except ValueError:
                continue
    return None


def to_seconds(value) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        parts = value.strip().split(':')
        try:
            nums = [float(p) for p in parts]
        except ValueError:
            return None
        total = 0.0
        for n in nums:
            total = total * 60 + n
        return total
    return None


# ---------------------------------------------------------------- twitch

def twitch_clips_24h(name: str) -> list[dict]:
    data = ytdlp_json(f'https://www.twitch.tv/{name}/clips?filter=clips&range=24hr',
                      '--flat-playlist', '--playlist-end', '100')
    return [e for e in data.get('entries') or [] if e.get('timestamp') and e.get('view_count') is not None]


class VodIndex:
    """Recent archived broadcasts of a channel, fetched lazily with start times."""

    def __init__(self, name: str):
        self.name = name
        self._ids: list[str] | None = None
        self._info: dict[str, dict] = {}

    def ids(self) -> list[str]:
        if self._ids is None:
            try:
                data = ytdlp_json(f'https://www.twitch.tv/{self.name}/videos?filter=archives&sort=time',
                                  '--flat-playlist', '--playlist-end', '6')
                self._ids = [e['id'] for e in data.get('entries') or [] if e.get('id')]
            except Exception as exc:  # noqa: BLE001
                log(f'{self.name}: could not list broadcasts ({exc})')
                self._ids = []
        return self._ids

    def info(self, vid: str) -> dict | None:
        if vid not in self._info:
            try:
                d = ytdlp_json(f'https://www.twitch.tv/videos/{vid.lstrip("v")}')
                self._info[vid] = {'id': vid.lstrip('v'), 'start': d.get('timestamp'), 'duration': d.get('duration'),
                                   'live': bool(d.get('is_live'))}
            except Exception as exc:  # noqa: BLE001
                log(f'{self.name}: broadcast {vid} unavailable ({exc})')
                self._info[vid] = None
        return self._info[vid]

    def containing(self, moment: float) -> dict | None:
        for vid in self.ids():
            info = self.info(vid)
            if not info or not info['start']:
                continue
            end = info['start'] + (info['duration'] or 0)
            if info['start'] <= moment <= end + 120 or (info['live'] and moment >= info['start']):
                return info
            if info['start'] + 86400 * 3 < moment:
                break
        return None


def download_hls_window(vod_id: str, start: float, end: float, out: Path) -> float:
    """Fetch the HLS segments covering [start, end]; returns where the file starts in the VOD."""
    url = run(['yt-dlp', '-g', '--no-warnings', '-f', HLS_FORMAT,
               f'https://www.twitch.tv/videos/{vod_id}']).strip().splitlines()[0]
    playlist = urllib.request.urlopen(url, timeout=60).read().decode()
    t, dur, init, segs = 0.0, 0.0, None, []
    for line in playlist.splitlines():
        if line.startswith('#EXT-X-MAP:') and 'URI="' in line:
            init = urllib.parse.urljoin(url, line.split('URI="', 1)[1].split('"', 1)[0])
        elif line.startswith('#EXTINF:'):
            dur = float(line[8:].split(',')[0])
        elif line and not line.startswith('#'):
            if t + dur > start and t < end:
                segs.append((t, urllib.parse.urljoin(url, line)))
            t += dur
    if not segs:
        raise RuntimeError(f'no stream segments cover {clock(start)}-{clock(end)}')
    raw = out.with_suffix('.raw')
    with open(raw, 'wb') as f:
        if init:
            f.write(urllib.request.urlopen(init, timeout=60).read())
        for _, seg in segs:
            f.write(urllib.request.urlopen(seg, timeout=60).read())
    # Remux to a clean MP4 starting at zero.
    run(['ffmpeg', '-loglevel', 'error', '-y', '-i', str(raw), '-c', 'copy', '-movflags', '+faststart', str(out)])
    raw.unlink(missing_ok=True)
    return segs[0][0]


def download_viewer_clip(url: str, out: Path) -> None:
    run(['yt-dlp', '-q', '--no-warnings', '-f', 'best[height<=720]/best', '-o', str(out), url])


def judge_window(gem, key: str, path: Path, channel: dict, clip: dict, window_len: float) -> dict | None:
    prompt = (
        f"You are the clip editor for {channel['name']}'s stream. This video is a {int(window_len)}-second window "
        f"around a moment viewers clipped (viewer clip title: \"{clip.get('title', '')}\", "
        f"{clip.get('view_count')} views).\n"
        f"What makes a great {channel['name']} clip: {channel['style'] or 'a genuinely entertaining moment'}\n\n"
        'Find the single most entertaining moment in this window and choose clip boundaries that include: '
        'a few seconds of setup leading into it, the insane moment itself, and the streamer\'s full reaction '
        'until it dies down. The clip must be 15 to 60 seconds long.\n'
        'Reply with ONLY a JSON object, no other text: {"keep": true or false, "score": 1-10 (10 = would go '
        'viral), "start_sec": number, "end_sec": number, "title": "short catchy clip title", '
        '"why": "one sentence on what happens and the reaction"}. Times are seconds from the start of THIS '
        'video. Set keep to false if nothing here is genuinely entertaining.'
    )
    if _GEMINI_OFF:
        raise SystemExit(f'Gemini skipped: {_GEMINI_OFF}')
    # Gemini only needs to see what happens, so upload a small 360p copy: big uploads get cut off by the
    # network proxy. Times stay the same, so the final clip is still cut from the full-quality window.
    preview = path.with_name(path.stem + '-preview.mp4')
    run(['ffmpeg', '-loglevel', 'error', '-y', '-i', str(path), '-vf', "scale=-2:'min(360,ih)'",
         '-c:v', 'libx264', '-preset', 'veryfast', '-b:v', '300k', '-maxrate', '300k', '-bufsize', '600k',
         '-c:a', 'aac', '-b:a', '64k', '-ac', '1', '-movflags', '+faststart', str(preview)], timeout=600)
    try:
        uploaded = with_retries(lambda: gem.upload_file(preview, key), f'upload {path.name}')
    finally:
        preview.unlink(missing_ok=True)
    try:
        result = ask_gemini(gem, key, {'uri': uploaded['uri'], 'mime_type': uploaded['mime_type']}, prompt,
                            600, f'judge {path.name}')
    finally:
        gem.delete_file(uploaded['name'], key)
    verdict = parse_json(result['text'])
    if not isinstance(verdict, dict):
        log(f'unreadable Gemini verdict: {result["text"][:200]}')
        return None
    return verdict


def compress(src: Path, dst: Path, start: float, end: float) -> int:
    length = max(1.0, end - start)
    height = 720 if length <= 30 else 540 if length <= 45 else 480
    audio = 96_000
    video = max(150_000, int(TARGET_BYTES * 8 / length) - audio)
    for _ in range(4):
        run(['ffmpeg', '-loglevel', 'error', '-y', '-ss', f'{start:.2f}', '-to', f'{end:.2f}', '-i', str(src),
             '-vf', f"scale=-2:'min({height},ih)'", '-c:v', 'libx264', '-preset', 'veryfast',
             '-b:v', str(video), '-maxrate', str(video), '-bufsize', str(video * 2),
             '-c:a', 'aac', '-b:a', str(audio), '-movflags', '+faststart', str(dst)], timeout=600)
        size = dst.stat().st_size
        if size <= MAX_UPLOAD_BYTES:
            return size
        video = int(video * 0.8)
        if video < 220_000 and height > 360:
            height = 360
    raise RuntimeError(f'could not get {dst.name} under the upload limit')


def process_twitch(channel: dict, args, gem, key, seen: set[str], now: float, work: Path) -> list[dict]:
    name = channel['name']
    try:
        clips = twitch_clips_24h(name)
    except Exception as exc:  # noqa: BLE001
        log(f'{name}: could not list clips ({exc})')
        return []
    if not clips:
        log(f'{name}: no clips in the last 24 hours')
        return []
    top_views = max(c['view_count'] for c in clips)
    hour = int(now // 3600) * 3600
    lo = hour - args.hours_ago * 3600
    hi = lo + max(1, min(args.window_hours, args.hours_ago)) * 3600
    bucket = sorted((c for c in clips if lo <= c['timestamp'] < hi), key=lambda c: -c['view_count'])
    # Several viewers often clip the same moment: keep the most viewed per 90-second span.
    picked: list[dict] = []
    for c in bucket:
        if any(abs(c['timestamp'] - p['timestamp']) < 90 for p in picked):
            continue
        picked.append(c)
    # Without Gemini there is no quality filter, so be much pickier on views alone.
    share, limit = (0.10, args.per_channel) if key else (0.25, min(args.per_channel, 1))
    threshold = max(args.min_views, int(top_views * share))
    candidates = [c for c in picked if c['view_count'] >= threshold and f"tw-{c['id']}" not in seen]
    candidates = candidates[:limit]
    log(f'{name}: {len(clips)} clips in 24h, {len(bucket)} in the review window, {len(candidates)} to review')

    vods = VodIndex(name)
    results = []
    for c in candidates:
        tag = f"tw-{c['id']}"
        try:
            created = float(c['timestamp'])
            length = float(c.get('duration') or 30)
            vod = vods.containing(created)
            window = work / f'{tag}-window.mp4'
            if vod:
                clip_end = created - vod['start']
                w_start = max(0.0, clip_end - length - LEAD_IN)
                w_end = clip_end + TAIL
                file_start = download_hls_window(vod['id'], w_start, w_end, window)
                source = f"https://www.twitch.tv/videos/{vod['id']}"
            else:
                log(f'{name}: no saved broadcast for clip {c["id"]}; using the viewer clip alone')
                download_viewer_clip(c['url'], window)
                file_start, source = None, None
            window_len = float(run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                    '-of', 'csv=p=0', str(window)]).strip() or 0)
            judged, verdict = False, None
            if key:
                try:
                    verdict = judge_window(gem, key, window, channel, c, window_len)
                    judged = True
                except SystemExit as exc:  # Gemini down or busy: still clip, picked by views
                    log(f'{name}: Gemini unavailable for {tag} ({str(exc).split(". Detail:")[0]}); '
                        'clipping it from viewer-clip views instead')
            if judged:
                if not verdict or not verdict.get('keep'):
                    log(f'{name}: Gemini passed on {tag} ({(verdict or {}).get("why", "no verdict")})')
                    results.append({'tag': tag, 'kept': False})
                    continue
                score = int(verdict.get('score') or 0)
                if score < args.min_score:
                    log(f'{name}: {tag} scored {score}, below {args.min_score}')
                    results.append({'tag': tag, 'kept': False})
                    continue
                start = to_seconds(verdict.get('start_sec'))
                end = to_seconds(verdict.get('end_sec'))
                title, why = verdict.get('title') or c.get('title'), verdict.get('why') or ''
            else:
                note = 'Gemini was unavailable' if key else 'no Gemini key yet'
                score, why, title = None, f'Picked by viewer clip views ({note}).', c.get('title')
                start = end = None
            if start is None or end is None or end <= start:
                # Fallback: the viewer clip plus lead-in and reaction tail.
                if file_start is not None:
                    start = max(0.0, (created - vod['start'] - length) - file_start - 10)
                    end = min(window_len, start + length + 10 + 20)
                else:
                    start, end = 0.0, window_len
            start, end = max(0.0, start), min(window_len, end)
            if end - start > 65:
                end = start + 65
            date = dt.datetime.fromtimestamp(created, dt.timezone.utc).strftime('%Y-%m-%d')
            score_txt = f' [{score}of10]' if score is not None else ''
            drive_title = f"{date} {name} - {clean(title)}{score_txt} [{tag}].mp4"
            final = work / f'{tag}.mp4'
            size = compress(window, final, start, end)
            window.unlink(missing_ok=True)
            at = (file_start + start) if file_start is not None else None
            results.append({
                'tag': tag, 'kept': True, 'platform': 'twitch', 'channel': name, 'path': str(final),
                'sha256': sha256(final), 'bytes': size, 'drive_title': drive_title, 'title': title,
                'score': score, 'why': why, 'length_sec': round(end - start, 1),
                'viewer_clip': c['url'], 'viewer_clip_views': c['view_count'],
                'full_quality': f'{source}?t={twitch_time(at)}' if source and at is not None else c['url'],
            })
            log(f'{name}: kept {tag} ({round(end - start)}s, score {score})')
        except SystemExit as exc:  # Gemini helper errors
            log(f'{name}: Gemini error on {tag}: {exc}')
        except Exception as exc:  # noqa: BLE001
            log(f'{name}: failed on {tag}: {exc}')
    return results


# ---------------------------------------------------------------- youtube

def process_youtube(channel: dict, args, gem, key, seen: set[str], seen_lines: list[str], today: str) -> dict | None:
    name = channel['name']
    done_today = sum(1 for line in seen_lines if line.startswith(today) and '[yt-' in line)
    if done_today >= args.youtube_daily:
        log(f'{name}: YouTube daily limit reached ({done_today})')
        return None
    if not key or _GEMINI_OFF:
        log(f'{name}: skipped ({"Gemini is unavailable this run" if key else "YouTube needs a Gemini key"})')
        return None
    try:
        data = ytdlp_json(f'https://www.youtube.com/{name}/streams', '--flat-playlist', '--playlist-end', '3')
    except Exception as exc:  # noqa: BLE001
        log(f'{name}: could not list streams ({exc})')
        return None
    streams = [e for e in data.get('entries') or []
               if e.get('id') and f"yt-{e['id']}" not in seen and e.get('live_status') not in ('is_live', 'is_upcoming')
               and (e.get('duration') or 0) > 600]
    if not streams:
        log(f'{name}: no new finished streams')
        return None
    stream = max(streams, key=lambda e: e.get('view_count') or 0)
    url = f"https://www.youtube.com/watch?v={stream['id']}"
    prompt = (
        f"You are the clip editor for {name}'s livestream. What makes a great {name} clip: "
        f"{channel['style'] or 'a genuinely entertaining moment'}\n\n"
        'Find the 3 most entertaining moments in this stream. For each, give boundaries that include a few '
        'seconds of setup, the insane moment itself, and the streamer\'s full reaction (15 to 60 seconds).\n'
        'Reply with ONLY a JSON array, no other text: [{"score": 1-10 (10 = would go viral), "start_sec": '
        'number, "end_sec": number, "title": "short catchy clip title", "why": "one sentence"}]. Times are '
        'seconds from the start of the video.'
    )
    try:
        result = ask_gemini(gem, key, {'uri': url}, prompt, 900, f'{name} stream')
    except SystemExit as exc:
        # Record the attempt anyway: a multi-hour stream is costly, so each one gets one try per day.
        reason = str(exc).split('. Detail:')[0]
        log(f'{name}: Gemini error: {reason}')
        return {'title': f"{today} {name} - {clean(stream.get('title'))} [yt-{stream['id']}] (not watched).txt",
                'text': f"{name}: {stream.get('title')}\n{url}\n\nGemini couldn't watch this stream ({reason}).\n"}
    moments = parse_json(result['text'])
    if isinstance(moments, dict):
        moments = [moments]
    lines, kept = [], 0
    for m in moments or []:
        start, end = to_seconds(m.get('start_sec')), to_seconds(m.get('end_sec'))
        score = int(m.get('score') or 0)
        if start is None or score < args.min_score:
            continue
        kept += 1
        lines.append(f"- [{score}/10] {m.get('title', 'moment')} ({clock(start)}-{clock(end or start + 30)})\n"
                     f"  {m.get('why', '')}\n  {url}&t={int(start)}s")
    title = f"{today} {name} - {clean(stream.get('title'))} [yt-{stream['id']}]"
    body = (f"{name}: {stream.get('title')}\n{url}\n\n"
            + ('\n'.join(lines) if lines else 'No moments scored high enough.')
            + '\n\n(YouTube blocks downloads from cloud machines, so these are timestamp links, not files.)\n')
    log(f'{name}: {kept} moments from {stream["id"]}')
    return {'title': title + '.txt', 'text': body}


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', required=True, help='work/output directory')
    ap.add_argument('--seen', help='text file of recent Drive file titles (IDs in [brackets] are skipped)')
    ap.add_argument('--channels', default=str(HERE / 'channels.txt'))
    ap.add_argument('--only', help='comma-separated channel names to process (for testing)')
    ap.add_argument('--hours-ago', type=int, default=24,
                    help='oldest Twitch clips to review, in hours (default 24)')
    ap.add_argument('--window-hours', type=int, default=18,
                    help='review Twitch clips made in this many hours starting --hours-ago ago (default 18: '
                         'clips 6-24 hours old, so they have had time to collect views)')
    ap.add_argument('--max-clips', type=int, default=4, help='most clips uploaded per run; the best are kept')
    ap.add_argument('--per-channel', type=int, default=2, help='Twitch moments reviewed per channel per run')
    ap.add_argument('--min-views', type=int, default=25)
    ap.add_argument('--min-score', type=int, default=7)
    ap.add_argument('--youtube-daily', type=int, default=1, help='YouTube streams Gemini watches per day')
    ap.add_argument('--no-youtube', action='store_true')
    args = ap.parse_args()

    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    seen, seen_lines = load_seen(args.seen)
    channels = load_channels(Path(args.channels))
    if args.only:
        wanted = {n.strip().lower() for n in args.only.split(',')}
        channels = [c for c in channels if c['name'].lower() in wanted]
    key = gemini_key()
    gem = gemini_module() if key else None
    log(f'{len(channels)} channels; Gemini {"on (" + gemini_model() + ")" if key else "OFF: no GEMINI_API_KEY"}')
    now = time.time()
    today = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')

    clips, rejected, reports = [], [], []
    for ch in channels:
        if ch['platform'] == 'twitch':
            results = process_twitch(ch, args, gem, key, seen, now, out)
            clips += [r for r in results if r.get('kept')]
            rejected += [r['tag'] for r in results if not r.get('kept')]
        elif ch['platform'] == 'youtube' and not args.no_youtube:
            rep = process_youtube(ch, args, gem, key, seen, seen_lines, today)
            if rep:
                reports.append(rep)
                seen_lines.append(rep['title'])

    # Keep the best clips (Gemini score first, then viewer-clip views); the rest wait for a later run.
    clips.sort(key=lambda c: (c['score'] is not None, c['score'] or 0, c['viewer_clip_views']), reverse=True)
    if len(clips) > args.max_clips:
        log(f'keeping the best {args.max_clips} of {len(clips)} clips this run')
        clips = clips[:args.max_clips]
    if clips or rejected:
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d %H:00 UTC')
        body = [f'Twitch clips, run {stamp}\n']
        if not clips:
            body.append('No moments were good enough this run.')
        for c in sorted(clips, key=lambda c: -(c['score'] or 0)):
            score = f"[{c['score']}/10] " if c['score'] is not None else ''
            body.append(f"- {score}{c['channel']}: {c['title']} ({c['length_sec']}s)\n  {c['why']}\n"
                        f"  Drive file: {c['drive_title']}\n  Full quality: {c['full_quality']}\n"
                        f"  Viewer clip ({c['viewer_clip_views']} views): {c['viewer_clip']}")
        # Moments Gemini turned down go in the title so later runs skip them (titles are the run history).
        passed = ''.join(f' [{t}]' for t in rejected)
        if rejected:
            body.append(f'\nPassed on {len(rejected)} moment(s):{passed}')
        reports.append({'title': f'{stamp[:13]}h Twitch clips{" - passed" + passed if rejected else ""}.txt',
                        'text': '\n'.join(body) + '\n'})

    manifest = {'generated': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                'gemini': bool(key), 'clips': clips, 'reports': reports}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    log(f'done: {len(clips)} clips, {len(reports)} reports -> {out / "manifest.json"}')
    print(out / 'manifest.json')
    return 0


if __name__ == '__main__':
    sys.exit(main())
