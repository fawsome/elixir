defmodule FAE do
  @spec download_source(String.t()) :: :ok
  def download_source(outfile \\ "README.md.orig") do
    response =
      :httpc.request(
        :get,
        {~c"https://raw.githubusercontent.com/h4cc/awesome-elixir/master/README.md", []},
        [],
        []
      )

    case response do
      {:ok, {{_version, 200, _phrase}, _headers, body}} ->
        readme = List.to_string(body)
        File.write!(outfile, readme)
        :ok

      other ->
        IO.puts("Failed to download source README.md.orig: #{inspect(other)}")
        raise "Failed to download upstream source README.md.orig"
    end
  end

  @spec markdown_to_url(String.t()) :: String.t() | nil
  def markdown_to_url(line) do
    case Regex.named_captures(~r/\((?<url>https?:\/\/.*?)\)/, line) do
      %{"url" => url} -> url
      _ -> nil
    end
  end

  @spec pad(integer, integer) :: String.t()
  def pad(number, count \\ 5) do
    # uses ensp instead of java/html space
    number |> Integer.to_string() |> String.pad_leading(count) |> String.replace(" ", "&ensp;")
  end

  @doc """
  Convert given GitHub URL to API
  """
  @spec url_to_api(String.t()) :: String.t()
  def url_to_api(url) do
    %URI{scheme: _scheme, host: _host, path: path} = URI.parse(url)
    path = path |> String.split("/", trim: true) |> Enum.take(2) |> Enum.join("/")
    "https://api.github.com/repos/#{path}"
  end

  @spec gitlab_url_to_api(String.t()) :: String.t()
  def gitlab_url_to_api(url) do
    %URI{scheme: _scheme, host: _host, path: path} = URI.parse(url)
    path = path |> String.split("/", trim: true) |> Enum.take(2) |> Enum.join("/")
    "https://gitlab.com/api/v4/projects/#{URI.encode_www_form(path)}"
  end

  def http_get(api_url, authen_header \\ nil) do
    IO.inspect(api_url, label: "API URL")

    headers =
      case authen_header do
        nil ->
          [{~c"User-Agent", ~c"Erlang/httpc"}]

        _ ->
          [
            {~c"User-Agent", ~c"Erlang/httpc"},
            authen_header
          ]
      end

    :httpc.request(:get, {String.to_charlist(api_url), headers}, [], [])
  end

  def query_gitlab_api(api_url) do
    # there are only 3 GitLab links in README.md, thus need GITLAB_ACCESS_TOKEN
    # coz we are not going to reach limit any time soon
    personal_access_token = System.get_env("GITLAB_ACCESS_TOKEN")

    authen_header =
      case personal_access_token do
        nil ->
          nil

        token ->
          {~c"Private-Token", String.to_charlist(token)}
      end

    http_get(api_url, authen_header)
  end

  # TODO @spec query_github_api(String.t()) :: {atom, {{String.t, integer, String.t}, atom, atom}}
  def query_github_api(api_url) do
    personal_access_token = System.get_env("GITHUB_ACCESS_TOKEN")

    authen_header =
      case personal_access_token do
        nil ->
          IO.puts("NO GITHUB_ACCESS_TOKEN set, would fail after a while due to API limit")
          nil

        token ->
          {~c"Authorization", ~c"bearer " ++ String.to_charlist(token)}
      end

    http_get(api_url, authen_header)
  end

  @spec parse_stats(list) :: {integer, integer, String.t() | nil}
  def parse_stats(body) do
    try do
      body = List.to_string(body)
      stars = Regex.named_captures(~r/\"stargazers_count\"\s*:\s*(?<count>\d+)/, body)
      forks = Regex.named_captures(~r/\"forks_count\"\s*:\s*(?<count>\d+)/, body)
      lang = Regex.named_captures(~r/\"language\"\s*:\s*\"(?<name>.*?)\"/, body)

      stars_count = (stars && stars["count"] && String.to_integer(stars["count"])) || 0
      forks_count = (forks && forks["count"] && String.to_integer(forks["count"])) || 0
      
      langname = (lang && lang["name"]) || nil
      sanitized_langname =
        case langname do
          nil -> nil
          name ->
            case Regex.run(~r/^[a-zA-Z0-9\s+#\-.]+/, name) do
              [valid_prefix] -> String.trim(valid_prefix)
              _ -> nil
            end
        end

      {stars_count, forks_count, sanitized_langname}
    rescue
      _ -> {0, 0, nil}
    end
  end

  def parse_gitlab_stats(body) do
    try do
      body = List.to_string(body)
      stars = Regex.named_captures(~r/\"star_count\"\s*:\s*(?<count>\d+)/, body)
      forks = Regex.named_captures(~r/\"forks_count\"\s*:\s*(?<count>\d+)/, body)
      stars_count = (stars && stars["count"] && String.to_integer(stars["count"])) || 0
      forks_count = (forks && forks["count"] && String.to_integer(forks["count"])) || 0
      {stars_count, forks_count, nil}
    rescue
      _ -> {0, 0, nil}
    end
  end

  @doc """
  extracts stats from a MarkDown syntax line
  """
  @spec extract_stats(String.t()) :: map
  def extract_stats(line) do
    try do
      url = markdown_to_url(line)

      cond do
        url && String.contains?(url, "//github.com/") ->
          api_url = url_to_api(url)
          response = query_github_api(api_url)

          case response do
            {:ok, {{_version, 200, _phrase}, _headers, body}} ->
              {stargazers_count, forks_count, language} = parse_stats(body)

              %{
                stats: true,
                line: line,
                stargazers_count: stargazers_count,
                forks_count: forks_count,
                language: language
              }

            {:ok, {{_version, 404, _phrase}, _, _}} ->
              %{stats: false, line: line}

            other ->
              IO.puts("GitHub API error/rate limit for #{url}: #{inspect(other)}")
              %{stats: nil, line: line}
          end

        url && String.contains?(url, "//gitlab.com/") ->
          api_url = gitlab_url_to_api(url)
          response = query_gitlab_api(api_url)

          case response do
            {:ok, {{_version, 200, _phrase}, _headers, body}} ->
              {stargazers_count, forks_count, nil} = parse_gitlab_stats(body)

              %{
                stats: true,
                line: line,
                stargazers_count: stargazers_count,
                forks_count: forks_count,
                language: nil
              }

            {:ok, {{_version, 404, _phrase}, _, _}} ->
              %{stats: false, line: line}

            other ->
              IO.puts("GitLab API error/rate limit for #{url}: #{inspect(other)}")
              %{stats: nil, line: line}
          end

        true ->
          %{stats: nil, line: line}
      end
    rescue
      error ->
        IO.puts("Failed to extract stats for line: #{line}. Error: #{inspect(error)}")
        %{stats: nil, line: line}
    end
  end

  @spec format_stats(String.t(), map) :: String.t()
  def format_stats(line, stats) do
    case stats do
      %{stats: false} ->
        "#{line} - :fire: :x: Broken link"

      %{
        stats: true,
        stargazers_count: stargazers_count,
        forks_count: forks_count,
        language: nil
      } ->
        String.replace_prefix(
          line,
          "* ",
          "* #{pad(stargazers_count)}⭐ #{pad(forks_count)}🍴 "
        )

      %{
        stats: true,
        stargazers_count: stargazers_count,
        forks_count: forks_count,
        language: language
      } ->
        String.replace_prefix(
          line,
          "* ",
          "* #{pad(stargazers_count)}⭐ #{pad(forks_count)}🍴 **[#{language}]** "
        )

      _ ->
        line
    end
  end

  @spec main() :: :ok
  def main() do
    IO.puts("Downloading latest Awesome Elixir Raw MarkDown")
    download_source("README.md.orig")
    input = File.read!("README.md.orig")

    _sample = """
    ## YAML
    *Libraries and implementations working with YAML.*

    * [fast_yaml](https://github.com/processone/fast_yaml) - Fast YAML is an Erlang wrapper for libyaml "C" library.
    * [yamerl](https://github.com/yakaz/yamerl) - YAML 1.2 parser in Erlang.
    * [yaml_elixir](https://github.com/KamilLelonek/yaml-elixir) - Yaml parser for Elixir based on native Erlang implementation.
    * [yomel](https://github.com/Joe-noh/yomel) - libyaml interface for Elixir.
    """

    # input = _sample

    {stats, lines} =
      input
      |> String.split("\n")
      |> Task.async_stream(fn line ->
        line = String.trim(line)
        if String.starts_with?(line, "* [") do
          extract_stats(line)
        else
          %{line: line, stats: nil}
        end
      end)
      |> Enum.reduce({%{}, []}, fn {:ok, item}, {stats, lines} ->
        case item do
          %{stats: nil, line: line} ->
            {stats, [line | lines]}

          %{stats: false, line: line} ->
            {stats, [format_stats(line, %{stats: false}) | lines]}

          %{stats: true, line: line} ->
            {Map.put(stats, line, item), [format_stats(line, item) | lines]}
        end
      end)

    top20 =
      Map.to_list(stats)
      |> Enum.sort_by(fn {_line, i} -> i.stargazers_count end, :desc)
      |> Enum.take(20)

    top20_pragraph =
      top20 |> Enum.map(fn {line, i} -> format_stats(line, i) end) |> Enum.join("\n")

    out = Enum.join(Enum.reverse(lines), "\n")

    header =
      "# Freaking Awesome Elixir ![Elixir CI](https://github.com/hvnsweeting/freaking_awesome_elixir/workflows/Elixir%20CI/badge.svg) [![Coverage Status](https://coveralls.io/repos/github/hvnsweeting/freaking_awesome_elixir/badge.svg?branch=master)](https://coveralls.io/github/hvnsweeting/freaking_awesome_elixir?branch=master)

Data updated at #{DateTime.to_iso8601(DateTime.utc_now())}

A curated list with Github stars and forks stats based on awesome [h4cc/awesome-elixir](https://github.com/h4cc/awesome-elixir).

To contribute new package to the list, please send a request to [h4cc/awesome-elixir](https://github.com/h4cc/awesome-elixir)"

    File.write!(
      "README.md",
      header <> "\n## Top 20 packages\n" <> top20_pragraph <> "\n\n" <> out
    )
  end
end
