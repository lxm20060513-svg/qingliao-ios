import urllib.request, json, time

TOKEN = "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"
RUN_ID = 31305423260
API = f"https://api.github.com/repos/lxm20060513-svg/qingliao-ios/actions/runs/{RUN_ID}"

def get(url):
    req = urllib.request.Request(url, headers={"Authorization": f"token {TOKEN}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

for i in range(30):
    try:
        run = get(API)
        status = run.get("status")
        concl = run.get("conclusion")
        print(f"[{i*60}s] status={status} conclusion={concl}", flush=True)
        if status == "completed":
            if concl == "success":
                # 拿 artifact
                arts = get(API.replace(f"/runs/{RUN_ID}", f"/runs/{RUN_ID}/artifacts"))
                items = arts.get("artifacts", [])
                print("BUILD_SUCCESS", flush=True)
                if items:
                    a = items[0]
                    print(f"ARTIFACT: {a['name']} id={a['id']} size={a['size_in_bytes']} expired={a['expired']}", flush=True)
                else:
                    print("ARTIFACT: none", flush=True)
            else:
                # 拿失败日志
                try:
                    req = urllib.request.Request(API.replace(f"/runs/{RUN_ID}", f"/runs/{RUN_ID}/jobs"), headers={"Authorization": f"token {TOKEN}"})
                    with urllib.request.urlopen(req, timeout=30) as r:
                        jobs = json.load(r)
                    for j in jobs.get("jobs", []):
                        for s in j.get("steps", []):
                            if s.get("conclusion") == "failure":
                                print(f"FAIL_STEP: {s['name']}", flush=True)
                except Exception as e:
                    print(f"FAIL_LOG_ERR: {e}", flush=True)
                print(f"BUILD_FAILED: {concl}", flush=True)
            break
    except Exception as e:
        print(f"poll err {e}", flush=True)
    time.sleep(60)
else:
    print("TIMEOUT_30MIN", flush=True)
