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

1. Push this repo to GitHub  
2. Render → New → Blueprint → select repo  
3. Open the `https://….onrender.com` URL on PC and phone  

Phone: scan QR on the dashboard, take a photo.

## Notes

- Mock inference until FPGA UDP is wired  
- Camera works best on HTTPS (Render free TLS)  
