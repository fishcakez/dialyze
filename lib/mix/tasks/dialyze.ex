defmodule Mix.Tasks.Dialyze do
  @moduledoc """
  Analyses the current Mix project using success typing.

  ## Examples

      # Build or check a PLT and use it to analysis a project
      mix dialyze

      # Use the existing PLT to analysis a project
      mix dialyze --no-check

      # Build or check the PLT for current environment but don't analyse
      mix dialyze --no-analyse

      # Skip compiling the project
      mix dialyze --no-compile

      # Find extra warnings during analysis
      mix dialyze --unmatched-returns --error-handling --race-conditions --underspecs

  The `--no-check` switch should only be used when the PLT for the current
  build environment (including Erlang and Elixir) has been checked, and
  no changes have been made to dependencies (including Erlang and Elixir). It is
  not required to check the PLT even if changes are made to dependencies but the
  success typing analysis will be less accurate and may make incorrect warnings.

  Below is a common pattern of use:

  ## Examples

      # Fetch deps
      mix deps.get
      # Possibly make changes to current application and then compile project
      mix compile
      # Run Dialyze for the first time to build a PLT and analyse
      mix dialyze
      # Fix Dialyzer warnings and analyse again (assuming same build
      # environment, Elixir version, Erlang version and deps)
      mix dialyze --no-check

  This task will automatically find all dependencies for the current build
  environment and add them to a PLT. The most common dependencies from
  Erlang/OTP and Elixir will be cached for each version of Erlang and Elixir and
  re-used between projects. If a PLT exists for the active versions of Erlang
  and Elixir, and the current build environment the PLT will be checked for
  consistency before analysis.

  This task tries to be as efficient as possible in reusing PLTs. If Erlang or
  Elixir is changed (including changing directories) without their versions
  changing, the next consistency check for each project and build environment
  will take longer as the PLT will need to be updated.

  The default warning flags are:

      --return --unused --improper-lists --fun-app --match --opaque
      --fail-call --contracts --behaviours --undefined-callbacks
      --no-unmatched-returns --no-error-handling --no-race-conditions
      --no-overspecs --no-underspecs, --no-unknown --no-overspecs --no-specdiffs

  For more information on `dialyzer` and success typing see:
  `http://www.erlang.org/doc/apps/dialyzer/index.html`
  """

  @shortdoc "Analyses the current Mix project using success typing"

  use Mix.Task

  @no_warnings [:return, :unused, :improper_lists, :fun_app,
    :match, :opaque, :fail_call, :contracts, :behaviours, :undefined_callbacks]
  @warnings [:unmatched_returns, :error_handling, :race_conditions, :overspecs,
    :underspecs, :unknown, :overspecs, :specdiffs]

  @spec run(OptionParser.argv) :: :ok
  def run(args) do
    {make, prepare, analysis, warnings} = parse_args(args)
    info("Finding applications for analysis")
    {mods, deps} = get_info(make)
    try do
      {plt, plt_beams} = ( plts_list(deps) |> prepare.() )
      analysis.(plt, mods, plt_beams, warnings)
    else
      [] -> :ok
      [_|_] = warnings ->
        print_warnings(warnings)
        Mix.raise "Dialyzer reported #{length(warnings)} warnings"
    catch
      :throw, {:dialyzer_error, reason} ->
        Mix.raise "Dialyzer error: " <> IO.chardata_to_string(reason)
    end
  end

  defp parse_args(args) do
    warn_switches = Enum.map(@no_warnings ++ @warnings, &{&1, :boolean})
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
    warnings = Enum.filter(@warnings, &Keyword.get(opts, &1, false))
    no_warnings = Enum.filter_map(@no_warnings,
      &(not Keyword.get(opts, &1, true)), &String.to_atom("no_#{&1}"))
    warnings ++ no_warnings
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
    [{deps_plt(), deps}, {elixir_plt(), [:elixir]},
      {erlang_plt(), [:erts, :kernel, :stdlib, :crypto]}]
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
    global_plt("erlang-#{otp_vsn()}_elixir-#{System.version()}")
  end

  defp deps_plt do
    name = "erlang-#{otp_vsn()}_elixir-#{System.version()}_deps-#{build_env()}"
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

  defp no_analyse(_plts, _mods, _plt_beams, _warnings), do: []

  defp analyse(plt, mods, plt_beams, warnings) do
    info("Finding modules for analysis")
    beams = resolve_modules(mods, HashSet.new())
    clashes = HashSet.intersection(beams, plt_beams)
    case HashSet.size(clashes) do
      0 ->
        plt_analyse(plt, beams, warnings)
      _ ->
        Mix.raise "Clashes with plt: " <>
          inspect(HashSet.to_list(clashes))
    end
  end

  defp no_check([{plt, _apps} | _plts]) do
    case plt_files(plt) do
      nil ->
        Mix.raise "Could not open #{plt}: #{:file.format_error(:enoent)}"
      beams ->
        {plt, beams}
    end
  end

  defp check(plts) do
    info("Finding suitable PLTs")
    find_plts(plts, [])
  end

  defp find_plts([{plt, apps} | plts], acc) do
    case plt_files(plt) do
      nil ->
        find_plts(plts, [{plt, apps, nil} | acc])
      beams ->
        apps_rest = Enum.flat_map(plts, fn({_plt2, apps2}) -> apps2 end)
        apps = Enum.uniq(apps ++ apps_rest)
        check_plts([{plt, apps, beams} | acc])
    end
  end

  defp find_plts([], acc) do
    check_plts(acc)
  end

  defp check_plts(plts) do
    {last_plt, beams, _cache} = Enum.reduce(plts, {nil, HashSet.new(), %{}},
      fn({plt, apps, beams}, acc) ->
        check_plt(plt, apps, beams, acc)
      end)
    {last_plt, beams}
  end

  defp check_plt(plt, apps, old_beams, {prev_plt, prev_beams, prev_cache}) do
    info("Finding applications for #{Path.basename(plt)}")
    cache = resolve_apps(apps, prev_cache)
    mods = cache_mod_diff(cache, prev_cache)
    info("Finding modules for #{Path.basename(plt)}")
    beams = resolve_modules(mods, prev_beams)
    check_beams(plt, beams, old_beams, prev_plt)
    {plt, beams, cache}
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

  defp resolve_apps(apps, cache) do
    apps
    |> Enum.uniq()
    |> Enum.filter_map(&(not Map.has_key?(cache, &1)), &app_info/1)
    |> Enum.into(cache)
  end

  defp app_info(app) do
    app_file = Atom.to_char_list(app) ++ '.app'
    case :code.where_is_file(app_file) do
      :non_existing ->
        error("Unknown application #{inspect(app)}")
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

  defp resolve_modules(modules, beams) do
    Enum.reduce(modules, beams, &resolve_module/2)
  end

  defp resolve_module(module, beams) do
    beam = Atom.to_char_list(module) ++ '.beam'
    case :code.where_is_file(beam) do
      path when is_list(path) ->
        path = Path.expand(path)
        HashSet.put(beams, path)
      :non_existing ->
        error("Unknown module #{inspect(module)}")
        beams
    end
  end

  defp check_beams(plt, beams, nil, prev_plt) do
    plt_ensure(plt, prev_plt)
    case plt_files(plt) do
      nil ->
        Mix.raise("Could not open #{plt}: #{:file.format_error(:enoent)}")
      old_beams ->
        check_beams(plt, beams, old_beams)
    end
  end

  defp check_beams(plt, beams, old_beams, _prev_plt) do
    check_beams(plt, beams, old_beams)
  end

  defp check_beams(plt, beams, old_beams) do
    remove = HashSet.difference(old_beams, beams)
    plt_remove(plt, remove)
    check = HashSet.intersection(beams, old_beams)
    plt_check(plt, check)
    add = HashSet.difference(beams, old_beams)
    plt_add(plt, add)
  end

  defp plt_ensure(plt, nil), do: plt_new(plt)
  defp plt_ensure(plt, prev_plt), do: plt_copy(prev_plt, plt)

  defp plt_new(plt) do
    info("Creating #{Path.basename(plt)}")
    plt = erl_path(plt)
    _ = plt_run([analysis_type: :plt_build, output_plt: plt,
      apps: [:erts]])
    :ok
  end

  defp plt_copy(plt, new_plt) do
    info("Copying #{Path.basename(plt)} to #{Path.basename(new_plt)}")
    File.cp!(plt, new_plt)
  end

  defp plt_add(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        (Mix.shell()).info("Adding #{n} modules to #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = erl_files(files)
        _ = plt_run([analysis_type: :plt_add, init_plt: plt,
          files: files])
        :ok
    end
  end

  defp plt_remove(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        info("Removing #{n} modules from #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = erl_files(files)
        _ = plt_run([analysis_type: :plt_remove, init_plt: plt,
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
        _ = plt_run([analysis_type: :plt_check, init_plt: plt])
        :ok
    end
  end

  defp plt_analyse(plt, files, warnings) do
    case HashSet.size(files) do
      0 ->
        []
      n ->
        info("Analysing #{n} modules with #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = Enum.map(files, &erl_path/1)
        plt_run([analysis_type: :succ_typings, plts: [plt], files: files,
          warnings: warnings])
    end
  end

  defp plt_run(opts) do
    :dialyzer.run([check_plt: false] ++ opts)
  end

  defp plt_info(plt) do
    erl_path(plt)
    |> :dialyzer.plt_info()
  end

  defp erl_files(files) do
    Enum.reduce(files, [], &[erl_path(&1)|&2])
  end

  defp erl_path(path) do
    encoding = :file.native_name_encoding()
    :unicode.characters_to_list(path, encoding)
  end

  defp plt_files(plt) do
    info("Looking up modules in #{Path.basename(plt)}")
    case plt_info(plt) do
      {:ok, info} ->
        Keyword.fetch!(info, :files)
        |> Enum.reduce(HashSet.new(), &HashSet.put(&2, Path.expand(&1)))
      {:error, :no_such_file} ->
        nil
      {:error, reason} ->
        Mix.raise("Could not open #{plt}: #{:file.format_error(reason)}")
    end
  end

  defp print_warnings(warnings) do
    _ = for warning <- warnings do
      _ = error(format_warning(warning))
      :ok
    end
    :ok
  end

  defp format_warning(warning) do
    :dialyzer.format_warning(warning, :fullpath)
    |> IO.chardata_to_string()
  end

  defp info(msg), do: apply(Mix.shell(), :info, [msg])

  defp error(msg), do: apply(Mix.shell(), :error, [msg])

end
