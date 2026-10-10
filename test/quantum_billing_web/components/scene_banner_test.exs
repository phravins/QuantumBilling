defmodule QuantumBillingWeb.SceneBannerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias QuantumBillingWeb.SceneBanner

  defp render(seed) do
    render_component(&SceneBanner.scene_banner/1, id: "banner", seed: seed)
  end

  test "the same seed always draws the same scene" do
    assert render(42) == render(42)
  end

  test "different seeds draw different scenes" do
    assert 1..12 |> Enum.map(&render/1) |> Enum.uniq() |> length() == 12
  end

  test "every seed draws a sky and mountains, with either pines or a lake" do
    for seed <- 1..60 do
      scene = SceneBanner.scene(seed)

      assert length(scene.ridges) in 4..5
      assert scene.label in ["Dawn", "Morning", "Golden hour", "Sunset", "Dusk", "Night"]
      assert scene.lake == nil != (scene.trees == nil)
    end
  end

  test "drawing a scene leaves the caller's random state alone" do
    :rand.seed(:exsss, 7)
    expected = :rand.uniform()

    :rand.seed(:exsss, 7)
    SceneBanner.scene(99)
    assert :rand.uniform() == expected
  end
end
