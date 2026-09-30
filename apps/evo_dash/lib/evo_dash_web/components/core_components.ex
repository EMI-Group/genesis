defmodule EvoDashWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)

  attr(:kind, :atom,
    values: [:info, :success, :error, :warning],
    doc: "used for styling and flash lookup"
  )

  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook="AutoClearFlash"
      role="alert"
      class="w-full pointer-events-auto"
      {@rest}
    >
      <div class={[
        "alert alert-soft !block relative w-full overflow-hidden rounded-lg !shadow-xl p-4 !ring-2 ring-current/15",
        @kind == :info && "alert-info",
        @kind == :success && "alert-success",
        @kind == :error && "alert-error",
        @kind == :warning && "alert-warning"
      ]}>
        <div class="flex items-start gap-3">
          <.icon
            :if={@kind == :info}
            name="hero-information-circle"
            class="size-5 shrink-0 text-current"
          />
          <.icon
            :if={@kind == :success}
            name="hero-check-circle"
            class="size-5 shrink-0 text-current"
          />
          <.icon :if={@kind == :error} name="hero-x-circle" class="size-5 shrink-0 text-current" />
          <.icon
            :if={@kind == :warning}
            name="hero-exclamation-triangle"
            class="size-5 shrink-0 text-current"
          />
          <div class="flex-1">
            <p :if={@title} class="text-sm font-semibold">{@title}</p>
            <p class="text-sm">{msg}</p>
          </div>
          <button type="button" class="opacity-60 hover:opacity-100 shrink-0" aria-label="close">
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <div class="absolute bottom-0 left-0 h-0.5 w-full bg-current/10">
          <div class="h-full animate-countdown bg-current/60" />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/projects"}>Home</.button>
  """
  attr(:rest, :global, include: ~w(href navigate patch method download name value disabled))
  attr(:class, :string)
  attr(:variant, :string, values: ~w(primary))
  slot(:inner_block, required: true)

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)

  attr(:type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)
  )

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"
  )

  attr(:errors, :list, default: [])
  attr(:checked, :boolean, doc: "the checked flag for checkbox inputs")
  attr(:prompt, :string, default: nil, doc: "the prompt for select inputs")
  attr(:options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2")
  attr(:multiple, :boolean, default: false, doc: "the multiple flag for select inputs")
  attr(:class, :string, default: nil, doc: "the input class to use over defaults")
  attr(:error_class, :string, default: nil, doc: "the input error class to use over defaults")

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot(:inner_block, required: true)
  slot(:subtitle)
  slot(:actions)

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "the function for generating the row id")
  attr(:row_click, :any, default: nil, doc: "the function for handling phx-click on each row")

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  slot :col, required: true do
    attr(:label, :string)
  end

  slot(:action, doc: "the slot for showing user actions in the last table column")

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{Gettext.gettext(EvoDashWeb.Gettext, "Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr(:title, :string, required: true)
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @git_svg File.read!(Path.join(__DIR__, "../../../assets/vendor/brand/git.svg"))
           |> String.replace("<svg", "<svg width=\"100%\" height=\"100%\"")
  @nix_svg File.read!(Path.join(__DIR__, "../../../assets/vendor/brand/nix.svg"))
           |> String.replace("<svg", "<svg width=\"100%\" height=\"100%\"")

  # GitHub octocat mark — embedded inline as a module attribute (single
  # one-off use, so no vendor asset file). Follows the git.svg/nix.svg
  # conventions: 24x24 viewBox, currentColor, fill-rule rules, width/height
  # 100% so the surrounding `.brand-icon` class controls the size.
  @github_svg ~S"""
  <svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" width="100%" height="100%"><title>GitHub</title><path fill="currentColor" fill-rule="evenodd" clip-rule="evenodd" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>
  """

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr(:name, :string, required: true)
  attr(:class, :string, default: "size-4")

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def icon(%{name: "brand-" <> _} = assigns) do
    ~H"""
    <span class={["inline-block shrink-0 brand-icon", @class]}>
      {raw(brand_svg_content(@name))}
    </span>
    """
  end

  defp brand_svg_content("brand-git"), do: @git_svg
  defp brand_svg_content("brand-nix"), do: @nix_svg
  defp brand_svg_content("brand-github"), do: @github_svg

  @doc """
  Renders a horizontal tab bar with pill-shaped tabs.

  ## Attributes

    * `:tabs` - list of maps with `:id` and `:label` keys
    * `:active` - the id of the active tab
    * `:phx_click` - optional event name for tab clicks (default: `"select_tab"`)

  ## Examples

      <.tabs tabs={[%{id: "tab1", label: "First"}, %{id: "tab2", label: "Second"}]} active="tab1" />
  """
  attr(:tabs, :list, required: true)
  attr(:active, :string, required: true)
  attr(:phx_click, :string, default: "select_tab")

  def tabs(assigns) do
    ~H"""
    <div class="bg-base-200/50 rounded-lg p-1 flex items-center gap-1 overflow-x-auto">
      <%= for tab <- @tabs do %>
        <button
          phx-click={@phx_click}
          phx-value-id={tab.id}
          class={[
            "px-4 py-2 rounded-md text-sm font-medium cursor-pointer transition-all whitespace-nowrap",
            @active == tab.id && "bg-base-100 shadow-sm text-base-content",
            @active != tab.id && "hover:bg-base-200/80 text-base-content/70 hover:text-base-content"
          ]}
        >
          {tab.label}
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a collapsible card section using native `<details>` / `<summary>`.

  ## Attributes

    * `:id` - required HTML id for the details element
    * `:title` - the card heading text
    * `:icon` - optional heroicon name shown before the title
    * `:color` - theme color (`:primary`, `:secondary`, `:accent`, `:info`, `:success`,
      `:warning`, `:error`), default `:primary`
    * `:open` - whether the card is expanded, default `true`

  ## Slots

    * `:inner_block` - the collapsible body content

  ## Examples

      <.collapsible_card id="settings" title="Settings" icon="hero-cog" color={:info}>
        <p>Content here</p>
      </.collapsible_card>
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:icon, :string, default: nil)

  attr(:color, :atom,
    values: [:primary, :secondary, :accent, :info, :success, :warning, :error],
    default: :primary
  )

  attr(:open, :boolean, default: true)

  slot(:inner_block, required: true)

  def collapsible_card(assigns) do
    ~H"""
    <details id={@id} open={@open} class="overflow-hidden group border-b border-base-300">
      <summary class="px-4 py-3 cursor-pointer select-none flex items-center gap-3 list-none hover:bg-base-200 transition-colors">
        <.icon :if={@icon} name={@icon} class="size-5 shrink-0 text-base-content/70" />
        <span class="font-semibold flex-1">{@title}</span>
        <.icon
          name="hero-chevron-down"
          class="size-5 shrink-0 text-base-content/70 transition-transform duration-200 group-open:rotate-180"
        />
      </summary>
      <div class="p-4">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  # {path d, transition-delay ms, brand-red?} — d verbatim from logo.svg,
  # delays precomputed from each bar's bounding-box center (x + y ascending,
  # 23ms per rank, same sweep as the Genesis evidence pages' brand mark).
  @brand_logo_segments [
    {"M5382 10301.97l154.1 -171.15c29.78,-31.27 52.18,-63.41 46.86,-90.01 -5.33,-26.59 -38.37,-47.63 -77.89,-65.02l-1882.85 -892.21c-37.86,-19.27 -77.69,-32.77 -113.38,-25.62 -35.69,7.15 -67.26,34.94 -94.77,67.3l-267.28 296.84c-29.45,30.8 -51.28,62.76 -45.3,88.16 5.99,25.4 39.79,44.26 79.89,58.67l1988.93 782.91c38.51,16.5 79.6,27.27 116.12,18.67 36.52,-8.61 68.48,-36.59 95.58,-68.55l-0 -0z",
     299, false},
    {"M4802.38 10945.72l195.51 -217.13c29.2,-30.45 50.64,-62.29 44.3,-86.98 -6.35,-24.68 -40.49,-42.24 -80.76,-54.82l-2055.93 -714.42c-38.78,-14.82 -80.55,-23.91 -117.55,-14.4 -36.99,9.51 -69.2,37.63 -96.03,69.31l-322.83 358.54c-28.69,29.75 -49.36,61.32 -42.45,84.78 6.91,23.45 41.39,38.78 81.63,48.22l2177.82 590.62c39.02,11.93 81.84,18.07 119.57,6.95 37.74,-11.12 70.39,-39.48 96.71,-70.67l0 0z",
     322, false},
    {"M3063.49 12876.95l319.71 -355.08c26.6,-26.92 44.31,-57.24 36.25,-77.1 -8.06,-19.85 -41.91,-29.23 -79.74,-29.97l-2593.58 -171.12c-38.37,-3.9 -83.18,-1.3 -122.54,14.69 -39.36,16 -73.3,45.38 -98.07,74.95l-489.47 543.62c-25.67,25.73 -42.17,55.39 -33.89,74.01 8.29,18.62 41.37,26.2 77.67,24.34l2762.76 0c37.77,1.37 82.89,-4.17 122.61,-21.86 39.72,-17.69 74.03,-47.51 98.29,-76.49l-0.01 0z",
     391, false},
    {"M9445.16 5533.28l-1539.93 -1140.18c-33.77,-26.35 -68.5,-46.64 -100.88,-43.39 -32.37,3.26 -62.37,30.07 -90.22,62.61l-214.93 238.7c-29.53,31.19 -52.99,63.69 -52.3,95.67 0.7,31.98 25.54,63.44 56.4,93.31l1337.25 1361.4c29.46,31.52 60.08,56.58 90.16,55.96 30.08,-0.62 59.64,-26.93 87.77,-59.64l443.93 -491c29.7,-31.26 52.78,-63.2 49.86,-92.55 -2.92,-29.35 -31.84,-56.11 -67.12,-80.9l0 -0z",
     161, false},
    {"M10169.72 4752.42l-1767.86 -916.26c-36.66,-20.31 -75,-34.92 -109.54,-28.64 -34.55,6.28 -65.29,33.45 -92.47,65.36l-195.5 217.13c-29.6,31.26 -52.44,63.14 -48.96,91.81 3.49,28.68 33.32,54.15 69.55,77.39l1596.52 1081.71c34.61,24.79 70.42,43.68 103.62,39.86 33.2,-3.82 63.79,-30.36 91.86,-62.36l379.91 -411.01c29.69,-30.39 52.22,-61.67 47.58,-88.19 -4.65,-26.51 -36.45,-48.28 -74.7,-66.79l0 -0z",
     115, false},
    {"M9050.92 3105.36l2057.02 684.4c37.49,13.83 79.1,22.19 116.75,13.48 37.66,-8.72 71.36,-34.52 98.95,-63.41l305.5 -299.89c29.24,-26.6 50.48,-55.98 44.6,-78.19 -5.88,-22.21 -38.88,-37.23 -77.44,-45.88l-2212.77 -585.12c-38.27,-11.45 -80.32,-17.2 -117.39,-6.15 -37.05,11.04 -69.11,38.87 -94.87,69.4l-156.65 173.98c-28.54,29.73 -49.43,60.89 -43.1,84.87 6.34,23.97 39.89,40.76 79.39,52.51l0 0z",
     23, false},
    {"M3643.12 12233.21l278.31 -309.1c27.57,-28.19 46.6,-59.13 38.91,-80.46 -7.68,-21.31 -42.07,-33 -81.29,-37.13l-2411.9 -354.32c-38.86,-7.08 -83.04,-8.02 -121.85,5.97 -38.81,13.98 -72.24,42.91 -97.65,73.15l-433.92 481.93c-26.75,27.12 -44.66,57.55 -36.65,77.61 8.01,20.07 41.96,29.77 80.04,30.99l2533.69 196.98 31.81 2.48c38.46,4.36 83.19,2.28 122.49,-13.43 39.3,-15.7 73.15,-45 98.02,-74.66l0 -0.01z",
     368, false},
    {"M14896.02 664.19l-3565.39 -119.99c-37.36,-2.6 -81.46,1.37 -120.23,17.85 -38.77,16.48 -72.22,45.5 -96.26,74.21l-78.93 87.67c-25.92,26.18 -43.07,55.8 -35.12,75.05 7.95,19.24 41.01,28.1 77.86,28.33l3320.62 178.3c9.95,0.84 20.09,1.31 30.1,1.31 74.22,0 146.58,-23.95 206.18,-68.14l284.11 -196.43c25.88,-15.37 43.58,-37.91 38.9,-53.87 -4.69,-15.95 -31.76,-25.34 -61.85,-24.28l0 -0.01z",
     138, false},
    {"M15946.03 0.39l-4129.62 0c-37.03,-1.34 -81.27,4.1 -120.21,21.43 -38.94,17.34 -72.58,46.58 -96.36,74.99l-59.51 66.08c-25.4,25.51 -41.86,54.75 -33.78,73.3 8.08,18.54 40.71,26.37 76.69,25.13l3841.84 59.26c5.11,0.14 10.29,0.29 15.43,0.29 79.73,0 157.84,-23.12 224.67,-66.53l300.24 -185.71c24.2,-12.48 40.64,-32.79 36.53,-47.26 -4.12,-14.47 -28.77,-23.1 -55.92,-20.99l0 -0z",
     230, false},
    {"M383.64 0.39l2152.28 0c74.06,-2.68 162.54,8.19 240.42,42.86 77.87,34.67 145.15,93.15 192.72 149.99l11335.39 12589.22c23.6,25.84 46.08,52.34 58.87 77.48 12.79,25.14 15.89,48.93 7.56 67.64 -8.33,18.7 -28.08,32.31 -55.32,39.64 -27.24,7.32 -61.98,8.34 -96.98,8.09l-2152.28 0c-74.07,2.68 -162.54,-8.19 -240.42,-42.86 -77.88,-34.67 -145.15,-93.15 -192.72,-149.99l-11335.38 -12589.22c-23.6,-25.84 -46.08,-52.34 -58.88,-77.48 -12.79,-25.14 -15.89,-48.93 -7.56,-67.63 8.33,-18.7 28.07,-32.31 55.32,-39.64 27.24,-7.32 61.97,-8.34 96.98,-8.09l-0.01 -0.01z",
     184, true},
    {"M4222.75 11589.46l236.91 -263.11c28.45,-29.4 48.74,-60.85 41.62,-83.78 -7.12,-22.93 -41.67,-37.33 -81.76,-45.44l-2232.48 -535.33c-39.05,-10.73 -82.26,-15.59 -120.28,-3.77 -38.03,11.81 -70.87,40.31 -96.97,71.26l-378.38 420.23c-27.77,28.49 -47.1,59.56 -39.54,81.23 7.57,21.67 42.04,33.96 81.52,38.94l2370.27 396.28c38.94,7.88 82.93,9.69 121.58,-3.8 38.65,-13.5 71.95,-42.31 97.51,-72.72l0.01 -0z",
     345, false},
    {"M7120.89 8370.75l29.9 -33.2c30.1,-31.8 54.04,-64.98 53.44,-97.69 -0.61,-32.72 -25.77,-64.98 -57.04,-95.63l-1385.99 -1428.36c-29.63,-29.8 -61,-67.67 -91.64,-67.1 -30.64,0.56 -60.57,39.58 -89.07,70.47l-100.64 111.77c-27.77,31.62 -63.23,65.2 -61.88,97.23 1.35,32.04 39.51,62.51 69.84,91.68l1448.02 1358.64c31.05,28.41 64,64.68 95.37,63.36 31.37,-1.33 61.16,-40.23 89.7,-71.15l0 -0z",
     207, false},
    {"M13118.29 1975.18l-2760 -340.59c-37.99,-6.04 -81.51,-5.95 -119.73,8.32 -38.22,14.27 -71.14,42.75 -95.87,72.21l-117.79 130.82c-27.15,27.8 -45.97,58.22 -38.5,79.32 7.47,21.1 41.23,32.9 79.83,37.43l2576.53 408.79c36.58,7.16 80.96,8.69 121.76,-2.65 40.8,-11.34 78.02,-35.55 105.66,-60.57l277.61 -233.65c28.14,-21.26 47.86,-47.7 42.24,-66.62 -5.61,-18.93 -36.56,-30.34 -71.74,-32.81l-0.01 -0z",
     46, false},
    {"M6541.26 9014.49l71.3 -79.19c30.25,-31.97 53.87,-64.71 51.42,-95.39 -2.45,-30.67 -30.97,-59.26 -65.89,-86.02l-1548.16 -1247.95c-33.42,-28.35 -67.81,-50.42 -100.22,-47.83 -32.41,2.59 -62.86,29.83 -91.36,63.12l-156.19 173.46c-30.22,31.93 -53.64,64.52 -50.43,94.23 3.21,29.72 33.05,56.54 69.4,81.28l1624.06 1165.47c34.77,26.32 70.59,46.52 103.82,42.93 33.23,-3.59 63.9,-30.98 92.26,-64.12l-0 0z",
     253, false},
    {"M12336.06 2637.97l-2464.66 -456.21c-38.22,-8.41 -81.18,-10.94 -118.93,1.87 -37.74,12.82 -70.28,40.98 -95.47,70.94l-137.22 152.4c-27.84,28.75 -47.66,59.55 -40.64,81.92 7.03,22.37 40.9,36.31 80.17,43.99l2299.61 536.71c37.24,10.06 80.44,14.6 119.77,4.31 39.33,-10.28 74.79,-35.39 102.33,-62.39l286.87 -262.35c28.8,-24.05 49.32,-52.1 43.45,-72.59 -5.87,-20.49 -38.12,-33.42 -75.28,-38.59l-0 -0z",
     0, false},
    {"M5961.63 9658.23l112.7 -125.17c30.14,-31.8 53.25,-64.22 49.23,-92.82 -4.03,-28.6 -35.2,-53.38 -72.95,-75.62l-1713.6 -1069.65c-36.1,-23.88 -73.46,-41.79 -107.6,-36.98 -34.15,4.8 -65.11,32.33 -93.22,65.25l-211.73 235.16c-29.97,31.55 -52.74,63.82 -47.98,91.32 4.76,27.51 37.05,50.25 75.88,69.9l1804.25 974.08c37.15,21.39 75.91,36.95 110.92,30.89 35.02,-6.06 66.28,-33.73 94.09,-66.37l-0 0z",
     276, false},
    {"M13963.55 1319.77l-3118.92 -230.93c-37.68,-4.14 -81.56,-1.93 -120.1,13.55 -38.55,15.48 -71.76,44.24 -96.11,73.29l-98.36 109.25c-26.5,26.95 -44.44,56.96 -36.68,77.04 7.76,20.08 41.22,30.22 78.96,32.34l2908.78 292.02c14.32,2.14 28.89,3.25 43.39,3.25 69.09,0 135.99,-24.54 188.69,-69.19l276.76 -212.12c27.19,-18.33 45.97,-42.93 40.77,-60.36 -5.2,-17.43 -34.39,-27.71 -67.18,-28.15l-0 0z",
     92, false},
    {"M10880.3 4017.38l-1986.24 -735.32c-37.9,-15.34 -78.53,-25.08 -114.57,-16.2 -36.04,8.88 -67.5,36.38 -93.93,67.58l-176.07 195.55c-29.19,30.64 -51.13,62.15 -45.89,88.18 5.24,26.03 37.67,46.59 76.44,63.55l1829.18 861.85c36.88,18.7 76.18,31.86 111.85,25.3 35.66,-6.56 67.71,-32.87 95.5,-63.48l335.42 -348.49c29.52,-28.76 51.43,-59.22 45.89,-83.39 -5.53,-24.17 -38.5,-42.07 -77.59,-55.14l0 0.01z",
     69, false}
  ]

  @doc ~S"""
  Renders the EvoX Genesis brand logo as an inline SVG.

  The 18 bars are the exact `<path>` data of `priv/static/images/logo.svg`,
  but the colors come from CSS (`app.css` `.brand-logo-seg*` rules): bars flip
  `#373435` ↔ `#d7d6d8` between light and dark themes, and each bar carries a
  precomputed `transition-delay` (23ms steps ordered by bar center, top-left →
  bottom-right), so a theme switch plays the per-bar sweep with zero JS.
  The diagonal bar stays brand red `#c8383c` in both themes.
  `prefers-reduced-motion` drops the transition entirely.

  The favicon still swaps `logo.svg`/`logo-alt.svg` separately; this component
  replaces only the in-page `<img>` pair.

  ## Examples

      <.brand_logo class="h-6 w-auto shrink-0" />
  """
  attr :class, :string, default: "h-6 w-auto"
  attr :alt, :string, default: "EvoX Genesis"
  attr :rest, :global

  def brand_logo(assigns) do
    assigns = assign(assigns, :segments, @brand_logo_segments)

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 16002.59 12975.69"
      fill-rule="evenodd"
      clip-rule="evenodd"
      role="img"
      aria-label={@alt}
      class={["brand-logo", @class]}
      {@rest}
    >
      <path
        :for={{d, delay, red?} <- @segments}
        d={d}
        class={["brand-logo-seg", red? && "brand-logo-seg-red"]}
        style={"transition-delay: #{delay}ms"}
      />
    </svg>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(EvoDashWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EvoDashWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
