Drawing webapp for live demo

Contents:
- `run.py`: lightweight HTTP server serving the phone canvas
- `preprocessing.py`: preprocessing utilities used to normalize drawn strokes to 28x28 images (MNIST)
- `phone_canvas/`: static UI files
- `requirements.txt`: minimal Python packages

Run locally (recommended inside a venv):

```bash
python -m pip install -r requirements.txt
python run.py --bind 127.0.0.1 --web-port 8765
```

Open `http://127.0.0.1:8765/` in a browser to view.
