# References

Code and design in this dashboard build on earlier work in the same monorepo
and related FPGA MNIST tooling.

## Drawing UI & stroke capture

| This project | Source |
|--------------|--------|
| `client/src/DigitCanvas.jsx` | `drawing_webapp/phone_canvas/app.js` |
| `client/src/DigitCanvas.css` | `drawing_webapp/phone_canvas/style.css` |
| Brush size `0.025`, recognize delay `550ms` | same as phone_canvas |

Upstream: `drawing_webapp/` in  
https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/drawing_webapp

## 28×28 MNIST normalization

| This project | Source |
|--------------|--------|
| `client/src/lib/mnistNormalize.js` | `drawing_webapp/preprocessing.py` |
| `DIGIT_BOX_SIZE = 20`, `MNIST_SIZE = 28` | `DIGIT_BOX_SIZE`, `MNIST_SIZE` |
| Mass centering | `_fit_and_center_digit` / `cv2.moments` |
| Quantize 0–127 | `quantize_normalized_image` (`input_scale=127`) |
| Photo ink mask | inspired by `segment_black_digit` |
| `client/src/lib/strokesToMnist.js` | stroke rasterization in `run.py` (`render_strokes`) |
| `client/src/lib/preprocessMnist.js` | photo path → same fit/center pipeline |

## FPGA / model context

| Topic | Source |
|-------|--------|
| Input: 784 int8 (0–127), 28×28 | Vakili MNIST P16 host / MLP designs |
| Output: 10 logits, `argmax` → digit | same |
| Eval mock metrics / confusion matrix shape | dashboard prototype; numbers from MNIST eval runs |
| Live FPGA UDP path | not wired yet; see `Vakili_P16_FPGA` / `reference_designs/vakili_mnist_p16` |

Repos:

- https://github.com/ahmaddaadaa/FPGA_Codes  
- https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/Vakili_P16_FPGA  
- https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/drawing_webapp  

## Runtime stack

- React + Vite (frontend)
- Express + `ws` (API + WebSocket)
- Deploy: Docker on Render (`Dockerfile`, `render.yaml`)
