defmodule QuantumBillingWeb.InvoiceTemplateDesignLiveTest do
  @moduledoc """
  The design pad.

  Every event names a block by id, and the ids come from the server, so these
  cover the stale and hostile cases as well as the happy ones: a pad left open in
  another tab must not be able to resurrect a removed block or drop one by
  sending a short list.
  """
  # Not async: concurrent default-template seeders deadlock in the sandbox.
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

  describe "the Page panel" do
    @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0,
           0>>

    test "frame, watermark and spacing save to the layout", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      view
      |> element("#page-options-form")
      |> render_change(%{
        "page" => %{"border" => "band", "watermark" => "status", "space-top" => "20mm"}
      })

      page = saved(template).page
      assert page.border == "band"
      assert page.watermark == "status"
      assert page.space_top == "20mm"
    end

    test "a background path in the params is ignored", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      render_change(view, "update_page", %{
        "page" => %{"background" => "/uploads/#{String.duplicate("ab", 16)}.png"}
      })

      assert saved(template).page.background == ""
    end

    test "uploading a letterhead sets it, records it, and Remove clears it",
         %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      file =
        file_input(view, "#background-upload-form", :background, [
          %{name: "letterhead.png", content: @png, type: "image/png"}
        ])

      render_upload(file, "letterhead.png")

      path = saved(template).page.background
      on_exit(fn -> QuantumBilling.Uploads.delete(path) end)

      assert QuantumBilling.DesignAssets.owned?(path)
      assert has_element?(view, "#remove-background")

      view |> element("#remove-background") |> render_click()
      assert saved(template).page.background == ""
    end

    test "a file that is not an image is refused", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      file =
        file_input(view, "#background-upload-form", :background, [
          %{name: "letterhead.png", content: "not a png", type: "image/png"}
        ])

      render_upload(file, "letterhead.png")

      assert has_element?(view, "#upload-error")
      assert saved(template).page.background == ""
    end
  end

  describe "the logo" do
    # A different file from the Page panel's, so cleanup there cannot race this.
    @logo_png <<0x89, "PNG\r\n", 0x1A, "\n", "logo-for-the-design-pad">>

    defp upload_logo(view, content \\ @logo_png) do
      view
      |> file_input("#logo-upload-form", :logo, [
        %{name: "logo.png", content: content, type: "image/png"}
      ])
      |> render_upload("logo.png")
    end

    defp logo_path, do: QuantumBilling.Settings.get_organization().doc_logo_path

    defp upload_letterhead(view) do
      view
      |> file_input("#background-upload-form", :background, [
        %{name: "letterhead.png", content: @logo_png, type: "image/png"}
      ])
      |> render_upload("letterhead.png")
    end

    test "uploading one sets the company logo and shows it inline", %{
      conn: conn,
      template: template
    } do
      {:ok, view, _html} = open(conn, template)
      refute has_element?(view, "#current-logo img")

      upload_logo(view)
      path = logo_path()
      on_exit(fn -> QuantumBilling.Uploads.delete(path) end)

      assert QuantumBilling.DesignAssets.path?(path)
      assert has_element?(view, "#current-logo img[src^='data:image/png;base64,']")
      assert has_element?(view, "#canvas-blocks img.qb-doc__logo[src^='data:image/png;base64,']")

      view |> element("#remove-logo") |> render_click()

      assert logo_path() == nil
      refute has_element?(view, "#current-logo img")
      refute File.exists?(Path.join(QuantumBilling.Uploads.directory(), Path.basename(path)))
    end

    test "a design without a logo block gets one", %{conn: conn, template: template} do
      doc = Templates.document_of(template)
      without = %{doc | blocks: Enum.reject(doc.blocks, &(&1.type == :logo))}

      {:ok, template} =
        Templates.update_template(template, %{
          "layout_xml" => QuantumBillingWeb.InvoiceDoc.Layout.to_xml(without)
        })

      {:ok, view, _html} = open(conn, template)
      upload_logo(view)
      path = logo_path()
      on_exit(fn -> QuantumBilling.Uploads.delete(path) end)

      assert [:logo | _rest] = types(saved(template))
    end

    test "a file that is not an image is refused", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      upload_logo(view, "not a png")

      assert has_element?(view, "#logo-error")
      assert logo_path() == nil
    end

    test "the letterhead preview is inline too", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      upload_letterhead(view)
      path = saved(template).page.background
      on_exit(fn -> QuantumBilling.Uploads.delete(path) end)

      assert has_element?(view, "#current-letterhead[src^='data:image/png;base64,']")
    end

    test "a logo uploaded as the letterhead can be moved to the logo", %{
      conn: conn,
      template: template
    } do
      {:ok, view, _html} = open(conn, template)
      upload_letterhead(view)
      path = saved(template).page.background
      on_exit(fn -> QuantumBilling.Uploads.delete(path) end)

      view |> element("#use-background-as-logo") |> render_click()

      assert logo_path() == path
      assert saved(template).page.background == ""
      assert has_element?(view, "#canvas-blocks img.qb-doc__logo[src^='data:image/png;base64,']")
      refute has_element?(view, "#current-letterhead")
      # Still recorded as a design image, so still this business's to serve.
      assert QuantumBilling.DesignAssets.owned?(path)
    end
  end

  describe "the newer blocks" do
    test "each can be added from the palette", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)

      for type <- ~w(payment custom_text image spacer) do
        view |> element(~s(button[phx-value-type="#{type}"])) |> render_click()
      end

      assert [:payment, :custom_text, :image, :spacer] -- types(saved(template)) == []
    end

    test "an image block takes an uploaded stamp", %{conn: conn, template: template} do
      {:ok, view, _html} = open(conn, template)
      view |> element(~s(button[phx-value-type="image"])) |> render_click()

      file =
        file_input(view, "#image-upload-form", :image, [
          %{name: "stamp.png", content: @png, type: "image/png"}
        ])

      render_upload(file, "stamp.png")

      [image] = Enum.filter(saved(template).blocks, &(&1.type == :image))
      on_exit(fn -> QuantumBilling.Uploads.delete(image.opts.path) end)

      assert QuantumBilling.DesignAssets.owned?(image.opts.path)
    end
  end
end
