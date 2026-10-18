defmodule QuantumBilling.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @required ~w(SECRET_KEY_BASE TOTP_ENCRYPTION_KEY SECRETS_ENCRYPTION_KEY DB_USERNAME DB_PASSWORD)
  @seed_vars ~w(SEED_ADMIN_EMAIL SEED_ADMIN_PASSWORD SEED_ADMIN_USERNAME)

  setup %{tmp_dir: tmp_dir} do
    vars = @required ++ @seed_vars ++ ~w(DATABASE_URL SMTP_HOST PHX_SERVER)
    original = Map.new(vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(vars, &System.delete_env/1)
    values = Map.new(@required, &{&1, Base.url_encode64(:crypto.strong_rand_bytes(48))})
    System.put_env(values)

    # Copy the actual config so its relative .env path uses an isolated directory.
    config_dir = Path.join(tmp_dir, "config")
    File.mkdir_p!(config_dir)
    runtime = Path.join(config_dir, "runtime.exs")
    File.cp!(Path.expand("../../config/runtime.exs", __DIR__), runtime)

    %{runtime: runtime, env_file: Path.join(tmp_dir, ".env"), values: values}
  end

  test "dev and test use configured database credentials and keys", context do
    for env <- [:dev, :test] do
      config = Config.Reader.read!(context.runtime, env: env)[:quantum_billing]
      repo = config[QuantumBilling.Repo]

      assert repo[:username] == context.values["DB_USERNAME"]
      assert repo[:password] == context.values["DB_PASSWORD"]

      assert config[QuantumBillingWeb.Endpoint][:secret_key_base] ==
               context.values["SECRET_KEY_BASE"]

      assert config[:totp_encryption_key] == context.values["TOTP_ENCRYPTION_KEY"]
      assert config[:secrets_encryption_key] == context.values["SECRETS_ENCRYPTION_KEY"]
    end
  end

  test "missing and blank credentials fail instead of using hardcoded defaults", context do
    for env <- [:dev, :test], name <- @required, missing <- [nil, "", "   "] do
      if is_nil(missing), do: System.delete_env(name), else: System.put_env(name, missing)

      assert_raise RuntimeError, ~r/environment variable #{name} is (missing|empty)/, fn ->
        Config.Reader.read!(context.runtime, env: env)
      end

      System.put_env(name, context.values[name])
    end
  end

  test "production requires nonblank secrets and a database URL", context do
    System.put_env("DATABASE_URL", "ecto://test-user:test-password@localhost/test-db")

    for name <- ~w(SECRET_KEY_BASE TOTP_ENCRYPTION_KEY SECRETS_ENCRYPTION_KEY DATABASE_URL) do
      value = System.fetch_env!(name)

      for missing <- [nil, "", "   "] do
        if is_nil(missing), do: System.delete_env(name), else: System.put_env(name, missing)

        assert_raise RuntimeError, ~r/environment variable #{name} is (missing|empty)/, fn ->
          Config.Reader.read!(context.runtime, env: :prod)
        end
      end

      System.put_env(name, value)
    end
  end

  test "local .env supplies credentials while real environment variables win", context do
    Enum.each(@required, &System.delete_env/1)

    File.write!(
      context.env_file,
      Enum.map_join(context.values, "\n", fn {k, v} -> "#{k}=#{v}" end)
    )

    override = Base.url_encode64(:crypto.strong_rand_bytes(48))
    System.put_env("DB_PASSWORD", override)
    config = Config.Reader.read!(context.runtime, env: :test)[:quantum_billing]

    assert config[QuantumBilling.Repo][:password] == override
    assert config[QuantumBilling.Repo][:username] == context.values["DB_USERNAME"]
    assert config[:totp_encryption_key] == context.values["TOTP_ENCRYPTION_KEY"]
    assert config[:secrets_encryption_key] == context.values["SECRETS_ENCRYPTION_KEY"]
  end

  test "seeds reject missing or blank account credentials before touching the database" do
    System.put_env(Map.new(@seed_vars, &{&1, Base.url_encode64(:crypto.strong_rand_bytes(24))}))

    for name <- @seed_vars do
      value = System.fetch_env!(name)

      for missing <- [nil, "", "   "] do
        if is_nil(missing), do: System.delete_env(name), else: System.put_env(name, missing)

        assert_raise RuntimeError,
                     "Set #{name} in your environment or .env before running seeds.",
                     fn ->
                       Code.eval_file(Path.expand("../../priv/repo/seeds.exs", __DIR__))
                     end
      end

      System.put_env(name, value)
    end
  end
end
