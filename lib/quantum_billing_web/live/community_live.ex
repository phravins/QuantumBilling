defmodule QuantumBillingWeb.CommunityLive do
  @moduledoc """
  The Community page: the people who built QuantumBilling, as avatar circles,
  and where to take part.

  Contributors come from `QuantumBilling.GitHub`, loaded after the page shows
  so a slow or unreachable GitHub never delays it. Avatars arrive as `data:`
  URIs; a contributor without one gets an initials circle.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.GitHub

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Community")
     |> assign(:repo_url, GitHub.repo_url())
     |> assign_async(:contributors, fn ->
       case GitHub.contributors() do
         {:ok, people} -> {:ok, %{contributors: people}}
         {:error, reason} -> {:error, reason}
       end
     end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      sidebar={:settings}
      active_sub={:community}
    >
      <div class="mx-auto w-full max-w-3xl px-1 py-4 sm:px-4">
        <.header>
          Community
          <:subtitle>QuantumBilling is open source and built in the open.</:subtitle>
        </.header>

        <section id="community-contributors" class="mt-6">
          <h2 class="text-sm font-semibold">Contributors</h2>
          <p class="mb-3 text-xs text-base-content/55">
            The people whose code is in QuantumBilling, most commits first.
          </p>

          <.card padding="p-5">
            <.async_result :let={people} assign={@contributors}>
              <:loading>
                <div id="contributors-loading" class="flex flex-wrap gap-2" aria-busy="true">
                  <span
                    :for={_ <- 1..12}
                    class="size-10 animate-pulse rounded-full bg-base-200 motion-reduce:animate-none"
                  />
                </div>
                <span class="sr-only">Loading contributors</span>
              </:loading>
              <:failed>
                <p id="contributors-unavailable" class="text-sm text-base-content/60">
                  GitHub could not be reached, so contributors are not shown right now.
                  <.link
                    href={"#{@repo_url}/graphs/contributors"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="underline underline-offset-2 hover:text-base-content"
                  >
                    See them on GitHub
                  </.link>
                </p>
              </:failed>

              <p :if={people == []} id="contributors-empty" class="text-sm text-base-content/60">
                No contributors yet.
              </p>
              <ul :if={people != []} id="contributors" class="flex flex-wrap gap-2">
                <li :for={person <- people}>
                  <.link
                    id={"contributor-#{person.login}"}
                    href={person.profile_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    title={"#{person.login} · #{person.contributions} #{commits(person.contributions)}"}
                    aria-label={"#{person.login}, #{person.contributions} #{commits(person.contributions)}"}
                    class={[
                      "flex size-10 items-center justify-center overflow-hidden rounded-full",
                      "bg-base-200 ring-2 ring-base-100 transition",
                      "hover:-translate-y-0.5 hover:ring-base-content/30 motion-reduce:transition-none",
                      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                    ]}
                  >
                    <img
                      :if={person.avatar}
                      src={person.avatar}
                      alt=""
                      width="40"
                      height="40"
                      class="size-full object-cover"
                    />
                    <span
                      :if={is_nil(person.avatar)}
                      class="text-xs font-semibold uppercase text-base-content/70"
                    >
                      {String.slice(person.login, 0, 2)}
                    </span>
                  </.link>
                </li>
              </ul>
            </.async_result>
          </.card>
        </section>

        <section id="community-involved" class="mt-8">
          <h2 class="text-sm font-semibold">Get involved</h2>
          <p class="mb-3 text-xs text-base-content/55">
            Report a bug, suggest a feature or send a pull request.
          </p>
          <.card padding="p-0" class="divide-y divide-base-300">
            <.community_link
              id="community-contribute"
              href={@repo_url}
              icon="hero-code-bracket"
              title="Contribute on GitHub"
              text="The code, how to run it, and how to send a change."
            />
            <.community_link
              id="community-issues"
              href={"#{@repo_url}/issues"}
              icon="hero-chat-bubble-left-right"
              title="Open issues"
              text="Bugs and ideas people are working on."
            />
            <.community_link
              id="community-conduct"
              href={"#{@repo_url}/blob/main/CODE_OF_CONDUCT.md"}
              icon="hero-hand-raised"
              title="Code of conduct"
              text="How we treat each other in the project."
            />
            <.community_link
              id="community-releases"
              href={"#{@repo_url}/releases"}
              icon="hero-megaphone"
              title="Release notes"
              text="What changed in each version."
            />
          </.card>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true

  defp community_link(assigns) do
    ~H"""
    <.link
      id={@id}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="group flex items-center gap-3 px-4 py-3 transition-colors hover:bg-base-200/60 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-base-content"
    >
      <span class="flex size-8 shrink-0 items-center justify-center rounded-field bg-base-200 text-base-content/70">
        <.icon name={@icon} class="size-4" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block text-sm font-medium">{@title}</span>
        <span class="block text-xs text-base-content/55">{@text}</span>
      </span>
      <.icon
        name="hero-arrow-up-right"
        class="size-4 text-base-content/40 transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
      />
      <span class="sr-only">(opens in a new tab)</span>
    </.link>
    """
  end

  defp commits(1), do: "commit"
  defp commits(_count), do: "commits"
end
