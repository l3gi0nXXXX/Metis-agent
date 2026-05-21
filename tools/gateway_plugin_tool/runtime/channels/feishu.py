# -*- coding: utf-8 -*-
"""
Feishu channel (extension) for gateway command-adapter.

当前实现范围：
- `send`（文本单聊/群聊）：调用飞书 OpenAPI IM messages 接口。
- `start_hook/stop_hook`：不再启动插件侧长连接进程；Feishu 入站由 Metis 原生网关负责。
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any, Dict, Tuple

import requests

from legacy_compat import get_channel_block, normalize_legacy_config

from channels import register_channel


def _runtime_dir(plugin_root: str) -> str:
    d = os.path.join(plugin_root, ".runtime")
    os.makedirs(d, exist_ok=True)
    return d


def _token_cache_path(plugin_root: str) -> str:
    return os.path.join(_runtime_dir(plugin_root), "feishu_tenant_token.json")


def _adapter_log_path(plugin_root: str) -> str:
    return os.path.join(_runtime_dir(plugin_root), "adapter.log")


def _log(plugin_root: str, text: str) -> None:
    try:
        with open(_adapter_log_path(plugin_root), "a", encoding="utf-8") as f:
            f.write(f"[{int(time.time())}] {text}\n")
    except OSError:
        pass


def _load_json(path: str) -> Dict[str, Any]:
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_json(path: str, obj: Dict[str, Any]) -> None:
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def _get_app_id_secret(cfg: Dict[str, Any]) -> Tuple[str, str]:
    ncfg = normalize_legacy_config(dict(cfg), "feishu")
    block = get_channel_block(ncfg, "feishu")

    # compatibility helper 会把 app-id/app-secret 归一化到 clientId/clientSecret
    app_id = (
        block.get("clientId")
        or block.get("appId")
        or block.get("app-id")
        or cfg.get("clientId")
        or cfg.get("appId")
        or cfg.get("app-id")
        or ""
    )
    app_secret = (
        block.get("clientSecret")
        or block.get("appSecret")
        or block.get("app-secret")
        or cfg.get("clientSecret")
        or cfg.get("appSecret")
        or cfg.get("app-secret")
        or ""
    )
    return str(app_id).strip(), str(app_secret).strip()


def _pid_path(plugin_root: str) -> str:
    return os.path.join(_runtime_dir(plugin_root), "feishu-ws.pid")


def _kill_pid_file(pid_file: str) -> None:
    try:
        if not os.path.isfile(pid_file):
            return
        with open(pid_file, encoding="utf-8") as f:
            s = (f.read() or "").strip()
        if not s:
            return
        pid = int(s)
        if pid <= 0:
            return
        try:
            import signal

            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
    except Exception:
        pass
    try:
        os.remove(pid_file)
    except OSError:
        pass


def _kill_all(plugin_root: str) -> None:
    _kill_pid_file(_pid_path(plugin_root))


def _get_tenant_access_token(plugin_root: str, app_id: str, app_secret: str) -> Tuple[bool, str]:
    cache = _load_json(_token_cache_path(plugin_root))
    token = str(cache.get("token") or "").strip()
    expire_at = cache.get("expireAt") or 0  # unix seconds

    # 提前 60s 刷新，避免时钟误差导致过期
    if token and isinstance(expire_at, (int, float)) and int(time.time()) < int(expire_at) - 60:
        return True, token

    url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    headers = {"Content-Type": "application/json; charset=utf-8"}
    body = {"app_id": app_id, "app_secret": app_secret}
    try:
        resp = requests.post(url, headers=headers, json=body, timeout=30)
        resp.raise_for_status()
        data = resp.json() if resp.content else {}
    except Exception as e:
        return False, f"feishu tenant_access_token request failed: {e!r}"

    token = str(data.get("tenant_access_token") or "").strip()
    expire = data.get("expire") or 0
    if not token:
        return False, f"feishu tenant_access_token missing in response: {data!r}"

    try:
        expire_s = int(expire) if int(expire) > 0 else 7200
    except Exception:
        expire_s = 7200
    _save_json(
        _token_cache_path(plugin_root),
        {"token": token, "expireAt": int(time.time()) + expire_s},
    )
    return True, token


def _send_text_to_feishu(chat_id: str, text: str, token: str) -> Tuple[bool, str]:
    url = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id"
    headers = {
        "Content-Type": "application/json; charset=utf-8",
        "Authorization": f"Bearer {token}",
    }

    # Metis 的实现：content 是“字符串形式的 JSON”
    content = json.dumps({"text": text}, ensure_ascii=False)
    body = {"receive_id": chat_id, "msg_type": "text", "content": content}

    try:
        resp = requests.post(url, headers=headers, json=body, timeout=30)
        resp.raise_for_status()
        data = resp.json() if resp.content else {}
    except Exception as e:
        return False, f"feishu send request failed: {e!r}"

    # Metis 判断成功：code == 0
    code = data.get("code")
    if code == 0:
        return True, ""
    msg = data.get("msg") or data.get("message") or str(data)
    return False, f"feishu send failed: code={code}, msg={msg}"


def start_hook(plugin_root: str, cfg: Dict[str, Any], channel_id: str) -> None:
    _ = (cfg, channel_id)
    _kill_all(plugin_root)
    _log(plugin_root, "[feishu] native Metis gateway owns inbound long-connect; plugin start hook is no-op")


def stop_hook(plugin_root: str, cfg: Dict[str, Any], channel_id: str) -> None:
    _ = (cfg, channel_id)
    _kill_all(plugin_root)


def op_send_feishu(plugin_root: str, cfg: Dict[str, Any], peer_id: str, text: str, reply_to: str) -> int:
    _ = reply_to
    chat_id = str(peer_id or "").strip()
    text = str(text or "").strip()
    if not chat_id or not text:
        sys.stderr.write("feishu send: empty chat_id or text\n")
        return 1

    app_id, app_secret = _get_app_id_secret(cfg)
    if not app_id or not app_secret:
        sys.stderr.write("feishu send: missing channels.feishu.clientId/clientSecret (or app-id/app-secret)\n")
        return 1

    _log(plugin_root, f"[feishu] send chat_id={chat_id[:32]} text_len={len(text)}")
    ok, token_or_err = _get_tenant_access_token(plugin_root, app_id, app_secret)
    if not ok:
        _log(plugin_root, f"[feishu] token error: {token_or_err}")
        sys.stderr.write(f"feishu send token error: {token_or_err}\n")
        return 1

    ok, err = _send_text_to_feishu(chat_id, text, token_or_err)
    if ok:
        _log(plugin_root, "[feishu] send ok")
        return 0
    _log(plugin_root, f"[feishu] send failed: {err}")
    sys.stderr.write(f"feishu send failed: {err}\n")
    return 1


register_channel("feishu", start_hook, stop_hook)
