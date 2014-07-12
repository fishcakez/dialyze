defmodule Mix.Tasks.Dialyze do

  def run(args) do
    {mods, deps} = get_info()
    prepare = prepare_fun(args)
    try do
      {plts, cache} = ( plts_list(deps) |> prepare.() )
      run(plts, mods, cache)
    else
      warnings ->
        print_warnings(warnings)
    catch
      :throw, {:dialyzer_error, reason} ->
        Mix.raise "Dialyzer error: " <> IO.chardata_to_string(reason)
    end
  end

  defp get_info() do
    infos = app_info_list()
    apps = Keyword.keys(infos)
    mods = Enum.flat_map(infos, fn({_, {mods, _deps}}) -> mods end)
    deps = Enum.flat_map(infos, fn({_, {_mods, deps}}) -> deps end)
    # Ensure apps not in deps.
    {mods, Enum.uniq(deps) -- apps}
  end

  defp app_info_list() do
    case Mix.Project.umbrella?() do
      true -> get_umbrella_info()
      false -> [get_app_info()]
    end
  end

  defp get_umbrella_info() do
    config = [build_path: Mix.Project.build_path()]
    for %Mix.Dep{app: app, opts: opts} <- Mix.Dep.Umbrella.loaded() do
      path = opts[:path]
      Mix.Project.in_project(app, path, config, fn(_) -> get_app_info() end)
    end
  end

  defp get_app_info() do
    Mix.Task.run("compile", [])
    Keyword.fetch!(Mix.Project.config(), :app)
      |> app_info()
  end

  defp prepare_fun(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean])
    case Keyword.get(opts, :check, true) do
      true -> &check/1
      false -> &ensure/1
    end
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

  defp run(plts, mods, plts_cache) do
    plts_mods = Enum.into(cache_mod_diff(plts_cache, %{}), HashSet.new())
    collisions = HashSet.intersection(plts_mods, Enum.into(mods, HashSet.new()))
    case HashSet.size(collisions) do
      0 ->
        files = resolve_beams(mods)
        plts_run(plts, files)
      _ ->
        Mix.raise "Collisions with plts: " <>
          inspect(HashSet.to_list(collisions))
    end
  end

  defp ensure(plts) do
    case Enum.all?(plts, fn({plt, _apps}) -> File.regular?(plt) end) do
      true ->
        {plt_list, _apps} = :lists.unzip(plts)
        {plt_list, %{}}
      false -> check(plts)
    end
  end

  defp check(plts) do
    Enum.map_reduce(plts, %{},
      fn({plt, apps}, cache) -> {plt, check(plt, apps, cache)} end)
  end

  defp check(plt, apps, old_cache) do
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

  ## ignore hipe
  defp app_info(:hipe) do
    {:hipe, {[], []}}
  end

  defp app_info(app) do
    app_file = Atom.to_char_list(app) ++ '.app'
    case :code.where_is_file(app_file) do
      :non_existing ->
        Mix.raise "Could not find #{app_file}"
      app_file ->
        Path.expand(app_file)
        |> read_app_info(app)
    end
  end

  defp read_app_info(app_file, app) do
    case :file.consult(app_file) do
      {:ok, [{:application, ^app, info}]} ->
        parse_app_info(info, app)
      {:ok, _} ->
        Mix.raise "Could not parse #{app_file}"
      _other ->
        Mix.raise "Could not read #{app_file}"
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
    HashSet.put(set, find_beam(module))
  end

  defp find_beam(module) do
    beam = Atom.to_char_list(module) ++ '.beam'
    case :code.where_is_file(beam) do
      path when is_list(path) ->
        Path.expand(path)
      :non_existing ->
        Mix.raise "#{inspect(module)} could not be found"
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
    end
  end

  defp plts_run(plts, files) do
    case HashSet.size(files) do
      0 ->
        []
      n ->
        plts_text = (Enum.map(plts, &Path.basename/1) |> Enum.join(" "))
        (Mix.shell()).info("Analysing #{n} modules with #{plts_text}")
        plts = Enum.map(plts, &erl_path/1)
        files = Enum.map(files, &erl_path/1)
        :dialyzer.run([analysis_type: :succ_typings, plts: plts, files: files])
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
      (Mix.shell()).error(format_warning(warning))
    end
    :ok
  end

  defp format_warning(warning) do
    :dialyzer.format_warning(warning, :fullpath)
    |> IO.chardata_to_string()
  end

end
