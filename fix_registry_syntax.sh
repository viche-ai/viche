cat lib/viche_web/controllers/registry_controller.ex | \
  sed 's/owner_id: conn.assigns\[:current_user_id\]//g' > lib/viche_web/controllers/registry_controller.ex.tmp
mv lib/viche_web/controllers/registry_controller.ex.tmp lib/viche_web/controllers/registry_controller.ex
