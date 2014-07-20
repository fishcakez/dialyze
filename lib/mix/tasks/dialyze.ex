defmodule Mix.Tasks.Dialyze do

  @warnings [:unmatched_returns, :error_handling, :race_conditions, :underspecs]

  def run(args) do
    {make, prepare, analysis, warnings} = parse_args(args)
    {mods, deps} = get_info(make)
    try do
      {plts, cache} = ( plts_list(deps) |> prepare.() )
      analysis.(plts, mods, cache, warnings)
    else
      warnings ->
        print_warnings(warnings)
    catch
      :throw, {:dialyzer_error, reason} ->
        Mix.raise "Dialyzer error: " <> IO.chardata_to_string(reason)
    end
  end

  defp parse_args(args) do
    warn_switches = Enum.map(@warnings, &{&1, :boolean})
    switches = [compile: :boolean, check: :boolean, analyse: :boolean] ++
      warn_switches
    {opts, _, _} = OptionParser.parse(args, [strict: switches])
    {make_fun(opts), prepare_fun(opts), analysis_fun(opts), warnings_list(opts)}
  end

  defp make_fun(opts) do
    case Keyword.get(opts, :compile, true) do
      true -> &compile/0
      false -> &no_compile/0
    end
  end

  defp prepare_fun(opts) do
    case Keyword.get(opts, :check, true) do
      true -> &check/1
      false -> &no_check/1
    end
  end

  defp analysis_fun(opts) do
    case Keyword.get(opts, :analyse, true) do
      true -> &analyse/4
      false -> &no_analyse/4
    end
  end

  defp warnings_list(opts) do
    Enum.filter(@warnings, &Keyword.get(opts, &1, false))
  end

  defp no_compile(), do: :ok

  defp compile(), do: Mix.Task.run("compile", [])

  defp get_info(make) do
    infos = app_info_list(make)
    apps = Keyword.keys(infos)
    mods = Enum.flat_map(infos, fn({_, {mods, _deps}}) -> mods end)
    deps = Enum.flat_map(infos, fn({_, {_mods, deps}}) -> deps end)
    # Ensure apps not in deps.
    {mods, Enum.uniq(deps) -- apps}
  end

  defp app_info_list(make) do
    case Mix.Project.umbrella?() do
      true -> get_umbrella_info(make)
      false -> [get_app_info(make)]
    end
  end

  defp get_umbrella_info(make) do
    config = [build_path: Mix.Project.build_path()]
    for %Mix.Dep{app: app, opts: opts} <- Mix.Dep.Umbrella.loaded() do
      path = opts[:path]
      Mix.Project.in_project(app, path, config, fn(_) -> get_app_info(make) end)
    end
  end

  defp get_app_info(make) do
    make.()
    Keyword.fetch!(Mix.Project.config(), :app)
      |> app_info()
  end

  defp plts_list(deps) do
    [{erlang_plt(), [:erts, :kernel, :stdlib]}, {elixir_plt(), [:elixir]},
     {deps_plt(), deps}]
  end

  defp erlang_plt(), do: global_plt("erlang-" <> otp_vsn())

  defp otp_vsn() do
    major = :erlang.system_info(:otp_release)
    vsn_file = Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])
    try do
      {:ok, contents} = File.read(vsn_file)
      String.split(contents, "\n", trim: true)
    else
      [full] ->
        full
      _ ->
        major
    catch
      :error, _ ->
        major
    end
  end

  defp elixir_plt() do
    global_plt("elixir-#{System.version()}_erlang-#{otp_vsn()}")
  end

  defp deps_plt do
    name = "deps-#{build_env()}_elixir-#{System.version()}_erlang-#{otp_vsn()}"
    local_plt(name)
  end

  defp build_env() do
    config = Mix.Project.config()
    case Keyword.fetch!(config, :build_per_environment) do
      true -> Atom.to_string(Mix.env())
      false -> "shared"
    end
  end

  defp global_plt(name) do
    Path.join(Mix.Utils.mix_home(), "dialyze_" <> name <> ".plt")
  end

  defp local_plt(name) do
    Path.join(Mix.Project.build_path(), "dialyze_" <> name <> ".plt")
  end


  defp no_analyse(_plts, _mods, _plts_cache, _warnings), do: []

  defp analyse(plts, mods, plts_cache, warnings) do
    (Mix.shell()).info("Finding modules for analysis")
    plts_mods = Enum.into(cache_mod_diff(plts_cache, %{}), HashSet.new())
    clashes = HashSet.intersection(plts_mods, Enum.into(mods, HashSet.new()))
    case HashSet.size(clashes) do
      0 ->
        files = resolve_beams(mods)
        plts_run(plts, files, warnings)
      _ ->
        Mix.raise "Clashes with plts: " <>
          inspect(HashSet.to_list(clashes))
    end
  end

  defp no_check(plts) do
    plt_list = Enum.map(plts, fn({plt, _apps}) -> plt end)
    {plt_list, %{}}
  end

  defp check(plts) do
    Enum.map_reduce(plts, %{},
      fn({plt, apps}, cache) -> {plt, check(plt, apps, cache)} end)
  end

  defp check(plt, apps, old_cache) do
    (Mix.shell()).info("Finding modules for #{Path.basename(plt)}")
    new_cache = resolve_modules(apps, old_cache)
    cache_mod_diff(new_cache, old_cache)
      |> resolve_beams()
      |> check_beams(plt)
    new_cache
  end

  defp cache_mod_diff(new, old) do
    Enum.flat_map(new,
      fn({app, {mods, _deps}}) ->
        case Map.has_key?(old, app) do
          true -> []
          false -> mods
        end
      end)
  end

  defp resolve_modules(apps, cache) do
    apps = Enum.uniq(apps)
    case Enum.filter_map(apps, &(not Map.has_key?(cache, &1)), &app_info/1) do
      [] ->
        cache
      infos ->
        cache = Enum.into(infos, cache)
        deps = Enum.flat_map(infos, fn({_app, {_mods, deps}}) -> deps end)
        resolve_modules(deps, cache)
    end
  end

  defp app_info(app) do
    app_file = Atom.to_char_list(app) ++ '.app'
    case :code.where_is_file(app_file) do
      :non_existing ->
        (Mix.shell()).error("Unknown application #{inspect(app)}")
        {app, {[], []}}
      app_file ->
        Path.expand(app_file)
        |> read_app_info(app)
    end
  end

  defp read_app_info(app_file, app) do
    case :file.consult(app_file) do
      {:ok, [{:application, ^app, info}]} ->
        parse_app_info(info, app)
      {:error, reason} ->
        Mix.raise "Could not read #{app_file}: #{:file.format_error(reason)}"
    end
  end

  defp parse_app_info(info, app) do
    mods = Keyword.get(info, :modules, [])
    apps = Keyword.get(info, :applications, [])
    inc_apps = Keyword.get(info, :included_applications, [])
    runtime_deps = get_runtime_deps(info)
    {app, {mods, runtime_deps ++ inc_apps ++ apps}}
  end

  defp get_runtime_deps(info) do
    Keyword.get(info, :runtime_dependencies, [])
    |> Enum.map(&parse_runtime_dep/1)
  end

  defp parse_runtime_dep(runtime_dep) do
    runtime_dep = IO.chardata_to_string(runtime_dep)
    regex =  ~r/^(.+)\-\d+(?|\.\d+)*$/
    [app] = Regex.run(regex, runtime_dep, [capture: :all_but_first])
    String.to_atom(app)
  end

  defp resolve_beams(modules) do
    Enum.reduce(modules, HashSet.new(), &resolve_beams/2)
  end

  defp resolve_beams(module, set) do
    case find_beam(module) do
      path when is_binary(path) ->
        HashSet.put(set, path)
      :non_existing ->
        (Mix.shell()).error("Unknown module #{inspect(module)}")
        set
    end
  end

  defp find_beam(module) do
    beam = Atom.to_char_list(module) ++ '.beam'
    case :code.where_is_file(beam) do
      path when is_list(path) -> Path.expand(path)
      :non_existing -> :non_existing
    end
  end

  defp check_beams(beams, plt) do
    old = plt_beams(plt)
    remove = HashSet.difference(old, beams)
    plt_remove(plt, remove)
    add = HashSet.difference(beams, old)
    plt_add(plt, add)
    remain = HashSet.intersection(old, beams)
    plt_check(plt, remain)
  end

  defp plt_new(plt) do
    (Mix.shell()).info("Creating #{Path.basename(plt)}")
    plt = erl_path(plt)
    _ = :dialyzer.run([analysis_type: :plt_build, output_plt: plt,
      apps: [:erts]])
    :ok
  end

  defp plt_add(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        (Mix.shell()).info("Adding #{n} modules to #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = plt_files(files)
        _ = :dialyzer.run([analysis_type: :plt_add, init_plt: plt,
          files: files])
        :ok
    end
  end

  defp plt_remove(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        (Mix.shell()).info("Removing #{n} modules from #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = plt_files(files)
        _ = :dialyzer.run([analysis_type: :plt_remove, init_plt: plt,
          files: files])
        :ok
    end
  end

  defp plt_check(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        (Mix.shell()).info("Checking #{n} modules in #{Path.basename(plt)}")
        plt = erl_path(plt)
        _ = :dialyzer.run([analysis_type: :plt_check, init_plt: plt])
        :ok
    end
  end

  defp plts_run(plts, files, warnings) do
    case HashSet.size(files) do
      0 ->
        []
      n ->
        plts_text = (Enum.map(plts, &Path.basename/1) |> Enum.join(" "))
        (Mix.shell()).info("Analysing #{n} modules with #{plts_text}")
        plts = Enum.map(plts, &erl_path/1)
        files = Enum.map(files, &erl_path/1)
        :dialyzer.run([analysis_type: :succ_typings, plts: plts, files: files,
          warnings: warnings])
    end
  end

  defp plt_info(plt) do
    erl_path(plt)
    |> :dialyzer.plt_info()
  end

  defp plt_files(files) do
    Enum.reduce(files, [], &[erl_path(&1)|&2])
  end

  defp erl_path(path) do
    encoding = :file.native_name_encoding()
    :unicode.characters_to_list(path, encoding)
  end

  defp plt_beams(plt) do
    case plt_info(plt) do
      {:ok, info} ->
        Keyword.fetch!(info, :files)
        |> Enum.reduce(HashSet.new(), &HashSet.put(&2, Path.expand(&1)))
      {:error, :no_such_file} ->
        plt_new(plt)
        plt_beams(plt)
      {:error, reason} ->
        Mix.raise "Could not open #{plt}: #{reason}"
    end
  end

  defp print_warnings(warnings) do
    _ = for warning <- warnings do
      _ = (Mix.shell()).error(format_warning(warning))
      :ok
    end
    :ok
  end

  defp format_warning(warning) do
    :dialyzer.format_warning(warning, :fullpath)
    |> IO.chardata_to_string()
  end

end
