# Dictation's speech models, pinned from upstream's own catalog, so the
# revision and digest of every model come from the same source tree the
# server is built from and are never pinned twice. Keyed by catalog id; each
# value is the model file, named the way t3code's model store names it.
#
# Silero VAD lives in a TypeScript constant, not the catalog: the server
# fetches it alongside any model for silence filtering and streaming.
{
  lib,
  fetchurl,
  src,
}: let
  catalog = (lib.importJSON "${src}/apps/server/src/speech/catalog.json").models;

  sileroSource = builtins.readFile "${src}/apps/server/src/speech/silero.ts";
  field = name: let
    m = builtins.match ''.*${name}: "([^"]+)".*'' sileroSource;
  in
    if m == null
    then throw "t3code-speech-models: no ${name} in silero.ts, its shape changed"
    else builtins.head m;
  silero = {
    id = field "id";
    revision = field "revision";
    filename = field "filename";
    sha256 = field "sha256";
  };

  fetchModel = model:
    (fetchurl {
      name = model.filename;
      url = "https://huggingface.co/${model.id}/resolve/${model.revision}/${model.filename}";
      sha256 = model.sha256;
    })
    .overrideAttrs (old: {
      passthru = (old.passthru or {}) // {inherit (model) id filename;};
    });
in {
  models = lib.listToAttrs (map (m: lib.nameValuePair m.id (fetchModel m)) catalog);
  vad = fetchModel silero;
}
