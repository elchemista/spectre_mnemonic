# Tiny Model2Vec Fixture

The demo writes these local model artifacts here when it runs:

- `config.json`
- `tokenizer.json`
- `model.safetensors`

This is intentionally tiny and offline-friendly. It exercises the real
`SpectreMnemonic.Embedding.Model2VecStatic` path without downloading a large
external model.
