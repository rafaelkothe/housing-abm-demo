# Notice

This repository is a demonstration snapshot of a Julia port of two Java
agent-based models of the housing market. It contains no research results.

## Upstream software

- **UK model:** [INET-Complexity/housing-model](https://github.com/INET-Complexity/housing-model).
  Described in Baptista et al. (2016) and Carro et al. (2023).
- **Spanish model:** [adrian-carro/housing-model-spain](https://github.com/adrian-carro/housing-model-spain).
  Described in Carro (2022).

Both are released under the MIT licence, Copyright (c) 2016 Daniel Tang and
Copyright (c) 2017 Adrian Carro.

The Julia code in this repository is a new implementation of these models.
It is released under the MIT licence (see `LICENSE`), which keeps the
upstream copyright notices.

## Data

- `data/uk`: unchanged copies of the input files of the UK upstream model.
- `data/spain`: unchanged copies of the input files of the Spanish upstream
  model, derived from the Banco de España *Encuesta Financiera de las
  Familias* (EFF).
- `data/euroarea`: one Python script, no data.

Full references are listed in `README.md` and `CITATION.cff`.
