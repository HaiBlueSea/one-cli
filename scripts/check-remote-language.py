#!/usr/bin/env python3
"""Exercise both remote UI languages and preserve in-flight input while switching."""
import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--assets', type=Path, default=Path(__file__).resolve().parents[1] / 'Resources/RemoteWeb')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checks, errors = {}, []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge', headless=True)
        for initial in ('zh-CN', 'en'):
            language = initial
            pending, inputs = [], []
            page = browser.new_page(viewport={'width': 390, 'height': 844})
            page.on('pageerror', lambda error: errors.append(str(error)))

            def route_request(route):
                path = urlsplit(route.request.url).path
                if path == '/api/sessions':
                    route.fulfill(json={'language': language, 'sessions': [
                        {'id': 'A', 'cwd': '/Users/demo', 'title': 'Terminal', 'state': 'working'},
                        {'id': 'B', 'cwd': '/demo', 'title': 'codex2', 'state': 'unknown'}]})
                elif path == '/api/screen':
                    route.fulfill(json={'type': 'snapshot', 'lines': ['原始输出 raw output 🙂'], 'revision': '1'})
                elif path == '/api/control':
                    route.fulfill(json={'leaseId': 'fixture-lease'})
                elif path == '/api/input':
                    inputs.append(json.loads(route.request.post_data))
                    pending.append(route)
                elif path == '/pair':
                    route.fulfill(json={'language': language, 'status': 'pending', 'confirmCode': '123456'})
                else:
                    file = args.assets / (path.lstrip('/') or 'index.html')
                    body = file.read_text()
                    if file.suffix == '.html':
                        body = body.replace('<html lang="zh-CN">', '<html lang="' + language + '">')
                    route.fulfill(body=body, content_type={'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[file.suffix])

            page.route('http://remote.local/**', route_request)
            page.goto('http://remote.local/')
            page.locator('#list button').first.wait_for()
            expected = '终端' if initial == 'zh-CN' else 'Terminal'
            checks[initial + '-home'] = page.locator('h1').inner_text() == expected
            if initial == 'en':
                checks['english-home-no-chinese'] = re.search(r'[\u4e00-\u9fff]', page.locator('body').inner_text()) is None
            checks[initial + '-command-name-preserved'] = page.locator('#list').inner_text().find('codex2') >= 0
            page.locator('#list button').first.click()
            page.locator('#request').click()
            page.wait_for_function("document.body.classList.contains('controlling')")
            checks[initial + '-request-feedback'] = page.locator('#ack').inner_text().startswith('已获得控制权' if initial == 'zh-CN' else 'Control granted')
            page.locator('#draft').fill('echo 中文')
            page.locator('#sendEnter').click()
            page.wait_for_timeout(100)
            language = 'en' if initial == 'zh-CN' else 'zh-CN'
            # Normal session refresh drives language changes, even with an input ACK pending.
            # Resume the tab through the same foreground refresh path used by the app.
            page.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
            # Input serialization defers polling until ACK, so first finish the submitted input.
            pending.pop(0).fulfill(json={'status': 'written', 'bytes': 11})
            page.wait_for_function("document.documentElement.lang === " + json.dumps(language))
            checks[initial + '-live-switch-keeps-control'] = page.locator('body').evaluate("e => e.classList.contains('controlling')")
            checks[initial + '-input-not-replayed'] = len(inputs) == 1 and inputs[0]['text'] == 'echo 中文'
            checks[initial + '-ack-retranslated'] = page.locator('#ack').inner_text() == ('Wrote 11 bytes.' if language == 'en' else '已写入 11 字节。')
            checks[initial + '-raw-output-preserved'] = page.locator('#term').inner_text() == '原始输出 raw output 🙂'
            page.locator('#draft').fill('unsent 草稿')
            language = initial
            page.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
            page.wait_for_function("document.documentElement.lang === " + json.dumps(language))
            checks[initial + '-draft-preserved'] = page.locator('#draft').input_value() == 'unsent 草稿'
            page.locator('#draft').fill('line one\nline two')
            page.locator('#sendEnter').click()
            checks[initial + '-multiline-confirmation'] = page.locator('#confirmPaste').is_visible() and page.locator('#confirmPaste').inner_text() == ('确认粘贴多行' if initial == 'zh-CN' else 'Confirm Multiline Paste')
            page.locator('#confirmPaste').click()
            page.locator('#sendEnter').click()
            page.wait_for_timeout(100)
            pending.pop(0).fulfill(json={'status': 'rejected', 'reason': 'no-control'})
            page.wait_for_function("!document.body.classList.contains('controlling')")
            checks[initial + '-rejection-localized'] = page.locator('#ack').inner_text() == ('已拒绝：没有控制权' if initial == 'zh-CN' else 'Rejected: No control')
            page.screenshot(path=str(args.output.parent / ('remote-' + initial + '.png')))
            page.goto('http://remote.local/?pair=1#c=fixture')
            page.locator('#pair p').wait_for()
            checks[initial + '-pairing'] = page.locator('#pair').inner_text() == ('请在 Mac 确认配对，确认码 123456' if initial == 'zh-CN' else 'Confirm pairing on your Mac. Code: 123456')
            page.close()
        browser.close()
    report = {'checks': checks, 'errors': errors, 'ok': all(checks.values()) and not errors}
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(report, indent=2, ensure_ascii=False))
    raise SystemExit(0 if report['ok'] else 1)


if __name__ == '__main__':
    main()
