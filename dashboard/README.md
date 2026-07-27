# MNIST FPGA Dashboard

Local + deployable dashboard for MNIST FPGA results, with phone photo capture.

## Dev

```bash
npm run dev
```

- UI: http://localhost:5173  
- API: http://localhost:3000  

## Production (local)

```bash
npm run prod
```

Opens on http://localhost:3000

## Deploy (Render)

Repo root has a `Dockerfile` that builds this `dashboard/` app.

1. Render → New → **Web Service**
2. Repo: `ahmaddaadaa/FPGA_Codes`, branch `main`
3. **Root Directory**: leave **empty** (use repo root)
4. Runtime: **Docker**
5. Dockerfile path: `Dockerfile`

Or use Blueprint with root `render.yaml`.

After deploy, open the `https://….onrender.com` URL on PC and phone.

## Notes

- Mock inference until FPGA UDP is wired  
- Camera works best on HTTPS (Render free TLS)  
