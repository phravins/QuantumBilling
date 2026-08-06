defmodule QuantumBillingWeb.InvoiceTemplateDesignLiveTest do
  @moduledoc """
  The design pad.

  Every event names a block by id, and the ids come from the server, so these
  cover the stale and hostile cases as well as the happy ones: a pad left open in
  another tab must not be able to resurrect a removed block or drop one by
  sending a short list.
  """
  # Not async: these seed a default design, and the partial unique index over
  # `invoice_templates.is_default` makes two transactions inserting one block
  # each other until the first ends — which in a sandbox is the whole test.
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Document

  setup :register_and_log_in_user

  setup do
    %{template: Templates.ensure_default()}
  end

  defp open(conn, template), do: live(conn, ~p"/invoice-templates/#{template.id}")

  # The saved row, re-parsed. Autosave means the database is the assertion — a
  # change that only reached the socket has not really happened.
  defp saved(template), do: template.id |> Templates.get_template!() |> Templates.document_of()

  defp types(document), do: Enum.map(document.blocks, & &1.type)

  describe "the canvas" do
    test "renders every block of the layout", %{conn: conn, template: template} do
      {:ok, _view, html} = open(conn, template)

      for block <- Templates.document_of(template).blocks do
        assert html =~ ~s(data-block-id="#{block.id}")
      end
    end

    test "requires authentication", %{template: template} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/invoice-templates/#{template.id}")
    end

    test "an unknown template redirects rather than crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/customization"}}} =
               live(conn, ~p"/invoice-templates/0")
    end
  end

  describe "adding and removing blocks" do
    test "adding a block saves it and takes it out of the palette",
         %{conn: conn, template: template} do
      {:ok, view, html} = open(conn, template)
      assert html =~ "Signature"

      html = view |> element(~s(button[phx-value-type="signature"])) |> render_click()

      assert :signature in types(saved(template))
      # Singleton: having added it, it is no longer on offer.
      refute html =~ ~s(phx-value-type="signature")
    end

    test "a required block cannot be removed", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      items = Enum.find(Templates.document_of(template).blocks, &(&1.type == :items))

      html =
        view
        |> element(~s(button[phx-value-id="#{items.id}"][phx-click="remove_block"]))
        |> render_click()

      assert html =~ "cannot be removed"
      assert :items in types(saved(template))
    end

    test "an optional block can be removed", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      block = Enum.find(Templates.document_of(template).blocks, &(&1.type == :amount_in_words))

      view
      |> element(~s(button[phx-value-id="#{block.id}"][phx-click="remove_block"]))
      |> render_click()

      refute :amount_in_words in types(saved(template))
    end
  end

  describe "reordering" do
    test "the move buttons swap a block with its neighbour",
         %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      [first, second | _rest] = Document.ids(Templates.document_of(template))

      view
      |> element(~s(button[phx-value-id="#{second}"][phx-value-dir="up"]))
      |> render_click()

      assert [^second, ^first | _rest] = Document.ids(saved(template))
    end

    test "the drag hook's order is applied", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      ids = Document.ids(Templates.document_of(template))
      shuffled = Enum.reverse(ids)

      render_hook(view, "reorder_blocks", %{"ids" => shuffled})

      assert Document.ids(saved(template)) == shuffled
    end

    # The case that matters. A client rendered before a block was added would
    # send a list missing it, and applying that verbatim would delete the block.
    test "a list that is not a permutation is ignored", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      ids = Document.ids(Templates.document_of(template))

      for bad <- [tl(ids), ["ghost" | ids], Enum.map(ids, fn _ -> "b1" end)] do
        render_hook(view, "reorder_blocks", %{"ids" => bad})

        assert Document.ids(saved(template)) == ids,
               "a #{length(bad)}-id list that was not a permutation changed the layout"
      end
    end
  end

  describe "block options" do
    test "changing a label reaches the saved layout", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      client = Enum.find(Templates.document_of(template).blocks, &(&1.type == :client))

      view |> element(~s(div[data-block-id="#{client.id}"])) |> render_click()

      render_change(view, "update_block", %{
        "_id" => client.id,
        "label" => "Invoice To",
        "align" => "right"
      })

      block = Enum.find(saved(template).blocks, &(&1.type == :client))
      assert block.opts.label == "Invoice To"
      assert block.opts.align == "right"
    end

    # `Catalog.cast_block/2` is a whitelist per block type, so a param naming an
    # option this block does not have is dropped rather than stored.
    test "an option the block does not have is ignored", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      client = Enum.find(Templates.document_of(template).blocks, &(&1.type == :client))

      view |> element(~s(div[data-block-id="#{client.id}"])) |> render_click()
      render_change(view, "update_block", %{"_id" => client.id, "box-width" => "999"})

      block = Enum.find(saved(template).blocks, &(&1.type == :client))
      refute Map.has_key?(block.opts, :box_width)
    end
  end

  describe "columns" do
    test "a column can be removed and re-added", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      items = Enum.find(Templates.document_of(template).blocks, &(&1.type == :items))

      view |> element(~s(div[data-block-id="#{items.id}"])) |> render_click()

      render_click(view, "toggle_child", %{"field" => "hsn_sac"})
      refute "hsn_sac" in columns(saved(template))

      render_click(view, "toggle_child", %{"field" => "hsn_sac"})
      assert "hsn_sac" in columns(saved(template))
    end

    test "a column an invoice cannot do without is refused",
         %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      items = Enum.find(Templates.document_of(template).blocks, &(&1.type == :items))

      view |> element(~s(div[data-block-id="#{items.id}"])) |> render_click()
      render_click(view, "toggle_child", %{"field" => "description"})

      assert "description" in columns(saved(template))
    end

    test "columns can be reordered", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      items = Enum.find(Templates.document_of(template).blocks, &(&1.type == :items))

      view |> element(~s(div[data-block-id="#{items.id}"])) |> render_click()
      render_click(view, "move_child", %{"field" => "hsn_sac", "dir" => "up"})

      assert Enum.take(columns(saved(template)), 3) == ["serial", "hsn_sac", "description"]
    end

    defp columns(document) do
      document.blocks
      |> Enum.find(&(&1.type == :items))
      |> Map.fetch!(:children)
      |> Enum.map(& &1.field)
    end
  end

  describe "the template itself" do
    test "renaming saves", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      render_change(view, "update_template", %{"name" => "Letterhead"})

      assert Templates.get_template!(template.id).name == "Letterhead"
    end

    test "a name that collides is reported rather than swallowed",
         %{conn: conn, template: template} do
      {:ok, _other} =
        Templates.create_template(%{"name" => "Taken", "layout_xml" => template.layout_xml})

      {:ok, view, _html} = open(conn, template)

      html = render_change(view, "update_template", %{"name" => "Taken"})

      assert html =~ "already taken"
      assert Templates.get_template!(template.id).name == "Classic"
    end

    test "the accent saves and is branding, not layout", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      render_change(view, "update_template", %{"accent" => "#B91C1C"})

      assert Templates.get_template!(template.id).accent == "#B91C1C"
      # The colour lives on the row, never inside the layout.
      refute Templates.get_template!(template.id).layout_xml =~ "B91C1C"
    end

    test "resetting restores the stock layout", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      block = Enum.find(Templates.document_of(template).blocks, &(&1.type == :amount_in_words))

      view
      |> element(~s(button[phx-value-id="#{block.id}"][phx-click="remove_block"]))
      |> render_click()

      refute :amount_in_words in types(saved(template))

      render_click(view, "reset_layout", %{})

      assert :amount_in_words in types(saved(template))
    end

    test "the page setup saves", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      render_change(view, "update_page", %{"page" => %{"margin" => "22mm", "font" => "serif"}})

      document = saved(template)
      assert document.page.margin == "22mm"
      assert document.page.font == "serif"
    end
  end

  # Autosave is the contract: there is no Save button, so a change that survives
  # a remount is the only proof it landed.
  test "changes survive leaving and coming back", %{conn: conn, template: template} do
    {:ok, view, _html} = open(conn, template)
    block = Enum.find(Templates.document_of(template).blocks, &(&1.type == :terms))

    view
    |> element(~s(button[phx-value-id="#{block.id}"][phx-click="remove_block"]))
    |> render_click()

    {:ok, _view, html} = open(conn, Templates.get_template!(template.id))

    refute html =~ ~s(data-block-id="#{block.id}")
  end
end
