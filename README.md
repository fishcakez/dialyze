Mix.Task.Dialyze
================

This project is no longer maintained, please consider using/contributing to https://github.com/Comcast/dialyzex.

Install
-------
Add as a dependency:
```elixir
defp deps() do
  [{:dialyze, "~> 0.2.0"}]
end
```
Fetch and compile:
```
mix do deps.get, deps.compile
```

Or install as archive:
```
git clone https://github.com/fishcakez/dialyze.git
cd dialyze
mix install
```

Usage
-----
Carry out success typing analysis on any mix project:
```
mix dialyze
```
To just check the PLT and skip success typing analysis:
```
mix dialyze --no-analyse
```
On subsequent calls for the same project checking the PLT can be
skipped. This should only be done if the build environment's
dependencies have not changed since the PLT were last checked:
```
mix dialyze --no-check
```
To skip compiling the project:
```
mix dialyze --no-compile
```
To turn on additional warnings:
```
mix dialyze --unmatched-returns --error-handling --race-conditions --underspecs
```
All switches are boolean and can be used in any combination, the default
is:
```
mix dialyze --compile --check --analyse --no-unmatched-returns --no-error-handling --no-race-conditions --no-underspecs
```

License
-------

Copyright 2014 James Fish

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
