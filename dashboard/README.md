# MNIST FPGA Dashboard

Dashboard for MNIST FPGA results: confusion matrix, draw/photo digit input, 28×28 preview, live WebSocket updates.

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

## Deploy (Render)

From the **FPGA_Codes** monorepo root (has root `Dockerfile`):

1. Connect repo `ahmaddaadaa/FPGA_Codes` on Render  
2. Root Directory empty, Docker runtime  
3. Open the `https://….onrender.com` URL  

Live example: https://fpga-codes.onrender.com  

## References

See **[REFERENCES.md](./REFERENCES.md)** for mappings to:

- `drawing_webapp/` (canvas + preprocessing)  
- Vakili MNIST P16 / FPGA host input format  

Upstream monorepo: https://github.com/ahmaddaadaa/FPGA_Codes  

## Notes

- Inference is mock until FPGA UDP is connected  
- Camera works best on HTTPS (Render TLS)  
