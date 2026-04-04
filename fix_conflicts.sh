# 1. lib/viche/agents.ex
cat lib/viche/agents.ex | \
  sed '/<<<<<<< HEAD/,/=======/c\
    owner_id = Map.get(attrs, :owner_id)\
    agent_id = generate_unique_id()\
\
    # Persist ownership record to database\
    changeset =\
      %AgentRecord{}\
      |> AgentRecord.changeset(%{\
        id: agent_id,\
        name: name,\
        capabilities: caps,\
        description: description,\
        user_id: owner_id\
      })\
\
    case Repo.insert(changeset) do\
      {:ok, _record} ->\
        child_opts = [\
          id: agent_id,\
          name: name,\
          capabilities: caps,\
          description: description,\
          registries: registries,\
          owner_id: owner_id\
        ]\
' | \
  sed '/<<<<<<< HEAD/d' | sed '/=======/d' | sed '/>>>>>>> origin\/main/d' > lib/viche/agents.ex.tmp
mv lib/viche/agents.ex.tmp lib/viche/agents.ex

# 2. lib/viche_web/controllers/registry_controller.ex
cat lib/viche_web/controllers/registry_controller.ex | \
  sed '/<<<<<<< HEAD/,/=======/c\
           owner_id: conn.assigns[:current_user_id]\
' | \
  sed '/>>>>>>> origin\/main/d' > lib/viche_web/controllers/registry_controller.ex.tmp
mv lib/viche_web/controllers/registry_controller.ex.tmp lib/viche_web/controllers/registry_controller.ex

# 3. lib/viche_web/plugs/api_auth.ex
cat lib/viche_web/plugs/api_auth.ex | \
  sed '/<<<<<<< HEAD/d' | sed '/=======/d' | sed '/>>>>>>> origin\/main/d' > lib/viche_web/plugs/api_auth.ex.tmp
mv lib/viche_web/plugs/api_auth.ex.tmp lib/viche_web/plugs/api_auth.ex

# 4. lib/viche_web/router.ex
cat lib/viche_web/router.ex | \
  sed '/<<<<<<< HEAD/,/=======/c\
  end\
\
  pipeline :require_auth do\
    plug VicheWeb.AuthPlug\
  end\
\
  pipeline :require_api_auth do\
    plug VicheWeb.ApiAuthPlug\
' | \
  sed '/>>>>>>> origin\/main/d' > lib/viche_web/router.ex.tmp
mv lib/viche_web/router.ex.tmp lib/viche_web/router.ex

