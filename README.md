Mix.Task.Dialyze
================

Install
-------

For Elixir >= 0.14.3
```
git clone https://github.com/fishcakez/dialyze.git
cd dialyze
mix install
```
For Elixir < 0.14.3
```
git clone https://github.com/fishcakez/dialyze.git
cd dialyze
mix do compile, archive, local.install --force
```

Usage
-----
Carry out success typing analysis on any mix project:
```
mix dialyze
```
