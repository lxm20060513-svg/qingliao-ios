#!/usr/bin/env python3
"""Watch CI run and download IPA from GitHub Release when done."""
import sys, time, urllib.request, json, os

def get_token():
    # 1) 优先 git remote URL 内嵌 token
    import subprocess
    try:
        result = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, cwd="/opt/data/qingliao_ios", timeout=10)
        url = result.stdout.strip()
        import re
        m = re.search(r'://[^:]*:([^@]*)@', url)
        if m:
            return m.group(1)
    except Exception:
        pass
    # 2) 兜底 .gh_cred（2026-08-31：ql_ipa2 已删，remote 无内嵌 token）
    try:
        cred = open("/opt/data/.gh_cred").read().strip()
        if cred:
            return cred
    except Exception:
        pass
    return None

def api(path, token):
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "hermes-watch"
    })
    resp = urllib.request.urlopen(req)
    return json.loads(resp.read())

def main():
    sha_prefix = sys.argv[1] if len(sys.argv) > 1 else None
    output_path = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/qingliao-unsigned.ipa"
    repo = "lxm20060513-svg/qingliao-ios"
    token = get_token()
    if not token:
        print("ERROR: Cannot extract GitHub token")
        sys.exit(1)

    print(f"Watching CI for SHA prefix: {sha_prefix}")
    print(f"Output: {output_path}")

    # Find the run
    run_id = None
    for attempt in range(120):  # 120 * 30s = 60 min max
        data = api(f"/repos/{repo}/actions/runs?per_page=5", token)
        for run in data.get("workflow_runs", []):
            if sha_prefix and run["head_sha"].startswith(sha_prefix):
                run_id = run["id"]
                status = run["status"]
                conclusion = run.get("conclusion", "")
                print(f"[{attempt}] Run {run_id}: {status} {conclusion}")
                if status == "completed":
                    if conclusion == "success":
                        print("CI SUCCESS! Downloading IPA...")
                        # v3.9.41（SR52）：下载失败以前只 print 一句就正常返回 → 退出码 0，
                        # 调用方（Hermes）看绿就把 NAS 上的**旧包**当新包装给用户（假绿）。
                        if not download_ipa(repo, token, output_path,
                                            not_before=run.get("created_at", "")):
                            sys.exit(1)
                        return
                    else:
                        print(f"CI FAILED: {conclusion}")
                        sys.exit(1)
                break
        else:
            print(f"[{attempt}] Run not found yet for SHA {sha_prefix}")
        time.sleep(30)

    print("TIMEOUT: CI did not complete in 60 minutes")
    sys.exit(1)

def download_ipa(repo, token, output_path, not_before=""):
    """取本次构建的 IPA。返回 True = 已落盘；False = 没拿到（调用方必须非 0 退出）。

    v3.9.41（SR52）：
      ① 找不到包以前只 print 不报错 → 配合上面的退出码闸门才是真修。
      ② 以前在**最近 5 个 release 里任取**第一个 .ipa：build-ios.yml 是固定往
         release tag `qingliao-ipa-2` 覆盖上传，但仓库里 v* tag 的 release 也带包，
         于是可能下到几周前的旧 IPA 还报「成功」。现在只认那个固定 release，
         并要求资产更新时间不早于本次 run 的 created_at（ISO-8601 UTC 可直接比大小）。
    """
    try:
        rel = api(f"/repos/{repo}/releases/tags/qingliao-ipa-2", token)
    except Exception as e:
        print(f"❌ 目标 release qingliao-ipa-2 读取失败：{e}")
        return False
    for asset in rel.get("assets", []):
        if not asset["name"].endswith(".ipa"):
            continue
        updated = asset.get("updated_at") or ""
        if not_before and updated and updated < not_before:
            print(f"❌ {asset['name']} 更新于 {updated}，早于本次 CI 的 {not_before} —— 是旧构建的产物，不下")
            return False
        print(f"Downloading {asset['name']} ({asset['size']} bytes)...")
        url = asset["browser_download_url"]
        req = urllib.request.Request(url, headers={
            "Authorization": f"token {token}",
            "User-Agent": "hermes-watch"
        })
        try:
            resp = urllib.request.urlopen(req)
            with open(output_path, "wb") as f:
                f.write(resp.read())
        except Exception as e:
            print(f"❌ 下载失败：{e}")
            return False
        size = os.path.getsize(output_path)
        print(f"Downloaded: {output_path} ({size} bytes)")
        if size < 1_000_000:
            # 包体积下限：正常 IPA 是几十 MB，几 KB 只可能是错误页/占位 → 别当成功
            print(f"❌ 落盘仅 {size} 字节，不像有效 IPA")
            return False
        return True
    print("❌ release qingliao-ipa-2 里没有 .ipa 资产")
    return False

if __name__ == "__main__":
    main()
