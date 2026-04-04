content = File.read!("lib/viche_web/router.ex")

old = """
  pipeline :require_auth do
    plug VicheWeb.AuthPlug
  end

  pipeline :require_api_auth do
    plug VicheWeb.ApiAuthPlug
  end

  pipeline :require_auth do
    plug VicheWeb.AuthPlug
  end

  pipeline :require_api_auth do
    plug VicheWeb.ApiAuthPlug
  end
"""

new = """
  pipeline :require_auth do
    plug VicheWeb.AuthPlug
  end

  pipeline :require_api_auth do
    plug VicheWeb.ApiAuthPlug
  end
"""

content = String.replace(content, old, new)

old_plug = """
  pipeline :api do
    plug :accepts, ["json"]
    plug VicheWeb.Plugs.ApiAuth
  end
"""

new_plug = """
  pipeline :api do
    plug :accepts, ["json"]
    plug VicheWeb.Plugs.ApiAuth
  end
"""

content = String.replace(content, old_plug, new_plug)

File.write!("lib/viche_web/router.ex", content)
