# containers

Deliberately minimal deploy targets, one per language, so the Jenkins pipelines in
`../ec2-deploy` and `../ecs-deploy` have something real to build/ship/run. Each one is a plain
HTTP server (no framework, no external deps beyond the base image) exposing:

- `GET /` — plain-text hello, so you can eyeball which app/host you hit
- `GET /health` — `200` + `{"status":"ok","service":"<name>"}`, used for post-deploy health
  checks and by `../status-notifier`

| app          | language | listens on (`$PORT`) |
|--------------|----------|-----------------------|
| `node-app`   | Node.js  | 3000                  |
| `python-app` | Python   | 5000                  |
| `go-app`     | Go       | 8080                  |
| `java-app`   | Java     | 8081                  |

Build any of them standalone:

```bash
docker build -t node-app containers/node-app
docker run --rm -p 3000:3000 node-app
curl localhost:3000/health
```
