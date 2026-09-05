module Invidious::Frontend::WatchPage
  extend self

  # A handy structure to pass many elements at
  # once to the download widget function
  struct VideoAssets
    getter full_videos : Array(Hash(String, JSON::Any))
    getter video_streams : Array(Hash(String, JSON::Any))
    getter audio_streams : Array(Hash(String, JSON::Any))
    getter captions : Array(Invidious::Videos::Captions::Metadata)

    def initialize(
      @full_videos,
      @video_streams,
      @audio_streams,
      @captions,
    )
    end
  end

  def download_widget(locale : String, video : Video, video_assets : VideoAssets) : String
    if CONFIG.disabled?("downloads")
      return "<p id=\"download\">#{I18n.translate(locale, "Download is disabled")}</p>"
    end

    if CONFIG.dmca_content.includes?(video.id)
      return "<p id=\"download\" class=\"notice\">#{I18n.translate(locale, "dmca_content")}</p>"
    end

    url = "/download"
    if (CONFIG.invidious_companion.present?)
      invidious_companion = CONFIG.invidious_companion.sample
      url = "#{invidious_companion.public_url}/download?check=#{invidious_companion_encrypt(video.id)}"
    end

    return String.build(4000) do |str|
      str << "<form"
      str << " class=\"panel panel--tight\""
      str << " action='" << HTML.escape(url) << "'"
      str << " method='post'"
      str << " rel='noopener noreferrer'"
      str << " target='_blank'>"
      str << '\n'

      # Hidden inputs for video id and title
      str << "<input type='hidden' name='id' value='" << video.id << "'/>\n"
      str << "<input type='hidden' name='title' value='" << HTML.escape(video.title) << "'/>\n"

      str << "\t<div class=\"field field--stack\">\n"

      str << "\t\t<label for='download_widget'>"
      str << I18n.translate(locale, "Download as: ")
      str << "</label>\n"

      str << "\t\t<select name='download_widget' id='download_widget'>\n"

      # Non-DASH videos (audio+video)

      video_assets.full_videos.each do |option|
        mimetype = option["mimeType"].as_s.split(";")[0]

        height = Invidious::Videos::Formats.itag_to_metadata?(option["itag"]).try &.["height"]?

        value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

        str << "\t\t\t<option value='" << value << "'>"
        str << (height || "~240") << "p - " << mimetype
        str << "</option>\n"
      end

      # DASH video streams

      video_assets.video_streams.each do |option|
        mimetype = option["mimeType"].as_s.split(";")[0]

        value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

        str << "\t\t\t<option value='" << value << "'>"
        str << option["qualityLabel"] << " - " << mimetype << " @ " << option["fps"] << "fps - video only"
        str << "</option>\n"
      end

      # DASH audio streams

      video_assets.audio_streams.each do |option|
        mimetype = option["mimeType"].as_s.split(";")[0]

        value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

        str << "\t\t\t<option value='" << value << "'>"
        str << mimetype << " @ " << (option["bitrate"]?.try &.as_i./ 1000) << "k - audio only"
        str << "</option>\n"
      end

      # Subtitles (a.k.a "closed captions")

      video_assets.captions.each do |caption|
        value = {"label": caption.name, "ext": "#{caption.language_code}.vtt"}.to_json

        str << "\t\t\t<option value='" << value << "'>"
        str << I18n.translate(locale, "download_subtitles", I18n.translate(locale, caption.name))
        str << "</option>\n"
      end

      # End of form

      str << "\t\t</select>\n"
      str << "\t</div>\n"

      str << "\t<button type=\"submit\" class=\"btn btn--accent\">\n"
      str << "\t\t<svg class=\"icon icon--sm\"><use href=\"#i-save\"/></svg>\n"
      str << "\t\t" << I18n.translate(locale, "Download") << '\n'
      str << "\t</button>\n"

      str << "</form>\n"
    end
  end

  # Il pannello «salva sul dispositivo».
  #
  # Il salvataggio offline vive tutto nel browser: qui il server si limita a
  # stampare l'elenco dei formati scaricabili e i dati del video, poi
  # offline_save.js fa il resto. Il pannello nasce nascosto e viene mostrato
  # dal JavaScript: senza JavaScript non funzionerebbe, e un pannello che non
  # funziona è peggio di un pannello che non c'è.
  #
  # Offriamo solo formati che si reggono da soli: i flussi progressivi
  # (video+audio nello stesso file) e una traccia di solo audio. I flussi
  # adattivi separati richiederebbero di rimettere insieme video e audio nel
  # browser, che è tutt'altro mestiere.
  def offline_widget(locale : String, video : Video, video_assets : VideoAssets) : String
    # Il download passa dal proxy dell'istanza: /latest_version rimanda a
    # /videoplayback, che si rifiuta di servire qualsiasi cosa se "dash" è
    # spento. Se manca uno dei tre interruttori non c'è niente da offrire.
    return "" if CONFIG.disabled?("downloads") || CONFIG.disabled?("local") || CONFIG.disabled?("dash")
    return "" if CONFIG.dmca_content.includes?(video.id)

    # Una diretta non ha un file da scaricare, ha un flusso che non finisce.
    return "" if video.live_now

    # Con Companion il file arriva da un altro dominio, che non è detto
    # risponda con gli header CORS necessari a leggerlo da JavaScript.
    return "" if CONFIG.invidious_companion.present?

    formats = [] of NamedTuple(itag: Int32, label: String, kind: String, ext: String, mime: String, size: Int64)

    video_assets.full_videos.each do |fmt|
      itag = fmt["itag"]?.try &.as_i
      next if itag.nil?

      mimetype = fmt["mimeType"]?.try &.as_s.split(";")[0] || "video/mp4"
      height = Invidious::Videos::Formats.itag_to_metadata?(fmt["itag"]).try &.["height"]?

      formats << {
        itag:  itag,
        label: "#{height || "~240"}p",
        kind:  "video",
        ext:   mimetype.split("/")[1],
        mime:  mimetype,
        size:  fmt["contentLength"]?.try &.as_s.to_i64? || 0_i64,
      }
    end

    # Una sola traccia audio, la migliore: chi vuole «solo audio» vuole
    # premere un pulsante, non scegliere fra sei bitrate.
    best_audio = video_assets.audio_streams
      .select { |fmt| fmt["itag"]? && fmt["mimeType"]? }
      .max_by? { |fmt| fmt["bitrate"]?.try &.as_i || 0 }

    if best_audio
      mimetype = best_audio["mimeType"].as_s.split(";")[0]
      ext = mimetype == "audio/mp4" ? "m4a" : mimetype.split("/")[1]

      formats << {
        itag:  best_audio["itag"].as_i,
        label: I18n.translate(locale, "offline_audio_only"),
        kind:  "audio",
        ext:   ext,
        mime:  mimetype,
        size:  best_audio["contentLength"]?.try &.as_s.to_i64? || 0_i64,
      }
    end

    return "" if formats.empty?

    data = {
      "id"             => video.id,
      "title"          => video.title,
      "author"         => video.author,
      "ucid"           => video.ucid,
      "lengthSeconds"  => video.length_seconds,
      "formats"        => formats,
      "saving"         => I18n.translate(locale, "offline_saving"),
      "saved"          => I18n.translate(locale, "offline_saved"),
      "failed"         => I18n.translate(locale, "offline_failed"),
      "unsupported"    => I18n.translate(locale, "offline_unsupported"),
      "confirm_delete" => I18n.translate(locale, "offline_confirm_delete"),
    }

    return String.build(2000) do |str|
      str << "<div id=\"offline_widget\" class=\"panel panel--tight offline-save\" hidden>\n"

      str << "\t<div class=\"field field--stack\">\n"
      str << "\t\t<label for=\"offline_format\">"
      str << I18n.translate(locale, "offline_save_as")
      str << "</label>\n"
      str << "\t\t<select id=\"offline_format\" name=\"offline_format\">\n"

      formats.each do |fmt|
        str << "\t\t\t<option value=\"" << fmt[:itag] << "\">"
        str << HTML.escape(fmt[:label]) << " &middot; " << fmt[:ext]
        str << " &middot; " << format_bytes(fmt[:size]) if fmt[:size] > 0
        str << "</option>\n"
      end

      str << "\t\t</select>\n"
      str << "\t</div>\n"

      str << "\t<button type=\"button\" id=\"offline_save\" class=\"btn btn--accent\">\n"
      str << "\t\t<svg class=\"icon icon--sm\"><use href=\"#i-save\"/></svg>\n"
      str << "\t\t<span>" << I18n.translate(locale, "offline_save") << "</span>\n"
      str << "\t</button>\n"

      # Avanzamento. Il valore vero lo scrive il JavaScript su --offline-progress.
      str << "\t<div id=\"offline_progress\" class=\"offline-save__progress\" hidden>\n"
      str << "\t\t<div class=\"offline-bar\" role=\"progressbar\" aria-valuemin=\"0\" aria-valuemax=\"100\"></div>\n"
      str << "\t\t<p id=\"offline_status\" class=\"offline-save__status\" aria-live=\"polite\"></p>\n"
      str << "\t\t<button type=\"button\" id=\"offline_cancel\" class=\"btn btn--quiet btn--sm\">"
      str << I18n.translate(locale, "offline_cancel")
      str << "</button>\n"
      str << "\t</div>\n"

      str << "\t<div id=\"offline_done\" class=\"offline-save__done\" hidden>\n"
      str << "\t\t<p id=\"offline_done_text\"></p>\n"
      str << "\t\t<div class=\"offline-save__actions\">\n"
      str << "\t\t\t<a class=\"btn btn--quiet btn--sm\" href=\"/offline\">"
      str << I18n.translate(locale, "offline_library")
      str << "</a>\n"
      str << "\t\t\t<button type=\"button\" id=\"offline_delete\" class=\"btn btn--danger btn--sm\">"
      str << I18n.translate(locale, "offline_remove")
      str << "</button>\n"
      str << "\t\t</div>\n"
      str << "\t</div>\n"

      str << "\t<p class=\"offline-save__note\">"
      str << I18n.translate(locale, "offline_keep_open")
      str << "</p>\n"

      str << "\t<script id=\"offline_data\" type=\"application/json\">"
      str << data.to_json.gsub("</", "<\\/")
      str << "</script>\n"

      str << "</div>\n"
    end
  end
end
