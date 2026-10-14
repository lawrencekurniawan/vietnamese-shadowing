# VieNeu FP32 model setup

The repository intentionally does not track the large VieNeu runtime model assets. Before building or running the app from a fresh checkout, prepare the local model assets:

```bash
uv run --with huggingface_hub --with numpy python scripts/prepare_vieneu_model.py
```

The script downloads only the `onnx_update` files from the pinned upstream revision `8b7e9cffb4b41918cb638b9f62f0a751184d14a6` of [pnnbao-ump/VieNeu-TTS-v3-Turbo](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo), validates the expected ONNX file sizes and tensor shapes, then generates `assets/vieneu/model/vieneu_heads.json` for the Rust engine. The upstream `vieneu_v3_heads.npz` is kept in the Hugging Face cache instead of the Flutter asset folder, because it is only an input to JSON generation and is not used by the runtime.

Run this setup command once when preparing a fresh checkout, or use `--force` to re-download the pinned revision. After preparation, Flutter bundles the files into the app; the installed app can still perform inference offline. Model preparation requires internet access and several hundred MB of free disk space.

## Build reminder

Run the preparation command before `flutter run`, `flutter build ios`, or `flutter build macos` whenever the runtime assets are not already present. Do not commit the generated `assets/vieneu/model/` directory.
