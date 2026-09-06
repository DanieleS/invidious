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

  # Un formato che si può tenere sul dispositivo.
  alias OfflineFormat = NamedTuple(
    itag: Int32,
    label: String,
    kind: String,
    ext: String,
    mime: String,
    size: Int64)

  # Il menu «scarica», nella riga delle azioni del video.
  #
  # Dentro ci sono due modi di portarsi via il video, e la differenza fra i
  # due è dove finisce:
  #
  #   * salvarlo per l'offline lo mette dentro il browser, dove Invidious lo
  #     sa ritrovare e riprodurre senza rete;
  #   * scaricare il file lo fa uscire dal browser e finire fra i file del
  #     telefono, dove lo trovano la galleria e qualsiasi altro lettore.
  #
  # Il secondo è quello che questo pannello ha sempre fatto, e resta identico:
  # stesso modulo, stessa destinazione, stessi formati. Le voci sono pulsanti
  # d'invio con il loro valore addosso, quindi funzionano anche senza
  # JavaScript — e il menu è un <details>, che senza JavaScript si apre lo
  # stesso.
  #
  # Sta in un menu e non in un pannello aperto perché nella pagina di un video
  # è un'eccezione, non il motivo per cui sei lì.
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

    offline = offline_formats(locale, video, video_assets)

    return String.build(4000) do |str|
      str << "<details class=\"menu\" id=\"download\">\n"
      str << "\t<summary class=\"btn\">\n"
      str << "\t\t<svg class=\"icon icon--sm\"><use href=\"#i-save\"/></svg>\n"
      str << "\t\t<span id=\"download_label\">" << I18n.translate(locale, "Download") << "</span>\n"
      str << "\t</summary>\n"

      str << "\t<div class=\"menu__pop\">\n"

      str << "\t\t<form"
      str << " action=\"" << HTML.escape(url) << "\""
      str << " method=\"post\""
      str << " rel=\"noopener noreferrer\""
      str << " target=\"_blank\">"
      str << '\n'

      # Hidden inputs for video id and title
      str << "\t\t<input type=\"hidden\" name=\"id\" value=\"" << video.id << "\"/>\n"
      str << "\t\t<input type=\"hidden\" name=\"title\" value=\"" << HTML.escape(video.title) << "\"/>\n"

      # Il gruppo dell'offline nasce nascosto: lo accende offline_save.js dopo
      # aver visto che il browser sa tenere i video. Senza JavaScript non
      # funzionerebbe, e una voce di menu che non fa niente è peggio di una
      # voce che non c'è.
      if !offline.empty?
        str << "\t\t<div id=\"offline_group\" class=\"menu__group\" hidden>\n"
        str << "\t\t\t<p class=\"menu__title\">" << I18n.translate(locale, "offline_save") << "</p>\n"

        offline.each do |fmt|
          str << "\t\t\t<button type=\"button\" class=\"menu__item\" data-offline-itag=\"" << fmt[:itag] << "\">"
          str << "<span>" << HTML.escape(fmt[:label]) << "</span>"
          str << "<span class=\"menu__meta\">" << fmt[:ext]
          str << " &middot; " << format_bytes(fmt[:size]) if fmt[:size] > 0
          str << "</span>"
          str << "</button>\n"
        end

        str << "\t\t</div>\n"
      end

      str << "\t\t<div class=\"menu__group\">\n"
      str << "\t\t\t<p class=\"menu__title\">" << I18n.translate(locale, "offline_download_file") << "</p>\n"

      # Non-DASH videos (audio+video)

      video_assets.full_videos.each do |option|
        mimetype = option["mimeType"].as_s.split(";")[0]

        height = Invidious::Videos::Formats.itag_to_metadata?(option["itag"]).try &.["height"]?

        value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

        str << download_item(value, "#{height || "~240"}p", mimetype)
      end

      # DASH video streams

      video_assets.video_streams.each do |option|
        mimetype = option["mimeType"].as_s.split(";")[0]

        value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

        str << download_item(
          value,
          option["qualityLabel"].to_s,
          "#{mimetype} @ #{option["fps"]}fps - video only"
        )
      end

      # DASH audio streams

      video_assets.audio_streams.each do |option|
        mimetype = option["mimeType"].as_s.split(";")[0]

        value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

        # In una voce di menu l'etichetta dice cos'è e il dettaglio dice
        # quale: "audio/mp4" come titolo non aiuta nessuno a scegliere.
        # Divisione intera, perché `/` fra interi in Crystal dà un decimale
        # e "130.0k" non lo scrive nessuno.
        str << download_item(
          value,
          I18n.translate(locale, "offline_audio_only"),
          "#{mimetype} @ #{option["bitrate"]?.try &.as_i.// 1000}k"
        )
      end

      # Subtitles (a.k.a "closed captions")

      video_assets.captions.each do |caption|
        value = {"label": caption.name, "ext": "#{caption.language_code}.vtt"}.to_json

        str << download_item(
          value,
          I18n.translate(locale, "download_subtitles", I18n.translate(locale, caption.name)),
          ""
        )
      end

      str << "\t\t</div>\n"
      str << "\t\t</form>\n"

      str << offline_states(locale, video, offline) if !offline.empty?

      str << "\t</div>\n"
      str << "</details>\n"
    end
  end

  # Una voce del menu che scarica il file.
  #
  # È un pulsante d'invio che si porta dietro il proprio valore: il modulo
  # arriva al server esattamente come quando al suo posto c'era un elenco a
  # discesa, quindi /download non si accorge del cambiamento e la cosa
  # continua a funzionare a JavaScript spento.
  private def download_item(value : String, label : String, meta : String) : String
    return String.build do |str|
      str << "\t\t\t<button type=\"submit\" class=\"menu__item\""
      str << " name=\"download_widget\" value=\"" << HTML.escape(value) << "\">"
      str << "<span>" << HTML.escape(label) << "</span>"
      str << "<span class=\"menu__meta\">" << HTML.escape(meta) << "</span>" if !meta.empty?
      str << "</button>\n"
    end
  end

  # I formati che si possono tenere sul dispositivo.
  #
  # Solo quelli che si reggono da soli: i flussi progressivi, che hanno video
  # e audio nello stesso file, e la migliore traccia di solo audio. I flussi
  # adattivi separati richiederebbero di rimettere insieme le due tracce nel
  # browser, che è tutt'altro mestiere.
  #
  # Vuoto vuol dire «qui non si può», e il gruppo non viene nemmeno stampato.
  private def offline_formats(locale : String, video : Video, video_assets : VideoAssets) : Array(OfflineFormat)
    formats = [] of OfflineFormat

    # Il salvataggio passa dal proxy dell'istanza: /latest_version rimanda a
    # /videoplayback, che si rifiuta di servire qualsiasi cosa se "dash" è
    # spento. Se manca uno dei due interruttori non c'è niente da offrire.
    return formats if CONFIG.disabled?("local") || CONFIG.disabled?("dash")

    # Con Companion il file arriva da un altro dominio, che non è detto
    # risponda con gli header CORS necessari a leggerlo da JavaScript.
    return formats if CONFIG.invidious_companion.present?

    # Una diretta non ha un file da scaricare, ha un flusso che non finisce.
    return formats if video.live_now

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

    return formats
  end

  # Avanzamento, esito e dati del salvataggio offline. Stanno in fondo al
  # menu, sotto le voci, e nascono tutti nascosti: li accende offline_save.js
  # quando c'è qualcosa da dire.
  private def offline_states(locale : String, video : Video, formats : Array(OfflineFormat)) : String
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
      "confirm_delete" => I18n.translate(locale, "offline_confirm_delete"),
    }

    return String.build(1500) do |str|
      # Il valore vero della barra lo scrive il JavaScript su --offline-progress.
      str << "\t\t<div id=\"offline_progress\" class=\"menu__state\" hidden>\n"
      str << "\t\t\t<div class=\"offline-bar\" role=\"progressbar\" aria-valuemin=\"0\" aria-valuemax=\"100\"></div>\n"
      str << "\t\t\t<p id=\"offline_status\" class=\"offline-save__status\" aria-live=\"polite\"></p>\n"
      str << "\t\t\t<p class=\"preference-description\">"
      str << I18n.translate(locale, "offline_keep_open")
      str << "</p>\n"
      str << "\t\t\t<button type=\"button\" id=\"offline_cancel\" class=\"btn btn--sm btn--quiet\">"
      str << I18n.translate(locale, "offline_cancel")
      str << "</button>\n"
      str << "\t\t</div>\n"

      # Fatto e non fatto sono due avvisi come quelli del resto del sito:
      # il bordo porta il colore, l'icona dice subito quale dei due è.
      str << "\t\t<div id=\"offline_done\" class=\"menu__state\" hidden>\n"
      str << "\t\t\t<div class=\"notice notice--good\">\n"
      str << "\t\t\t\t<svg class=\"icon notice__icon\"><use href=\"#i-check\"/></svg>\n"
      str << "\t\t\t\t<div class=\"notice__body\">\n"
      str << "\t\t\t\t\t<p id=\"offline_done_text\"></p>\n"
      str << "\t\t\t\t\t<div class=\"cluster\">\n"
      str << "\t\t\t\t\t\t<a class=\"btn btn--sm btn--quiet\" href=\"/offline\">"
      str << I18n.translate(locale, "offline_library")
      str << "</a>\n"
      str << "\t\t\t\t\t\t<button type=\"button\" id=\"offline_delete\" class=\"btn btn--sm btn--danger\">"
      str << I18n.translate(locale, "offline_remove")
      str << "</button>\n"
      str << "\t\t\t\t\t</div>\n"
      str << "\t\t\t\t</div>\n"
      str << "\t\t\t</div>\n"
      str << "\t\t</div>\n"

      str << "\t\t<div id=\"offline_error\" class=\"menu__state\" hidden>\n"
      str << "\t\t\t<div class=\"notice notice--bad\">\n"
      str << "\t\t\t\t<svg class=\"icon notice__icon\"><use href=\"#i-alert\"/></svg>\n"
      str << "\t\t\t\t<div class=\"notice__body\"><p id=\"offline_error_text\"></p></div>\n"
      str << "\t\t\t</div>\n"
      str << "\t\t</div>\n"

      str << "\t\t<script id=\"offline_data\" type=\"application/json\">"
      str << data.to_json.gsub("</", "<\\/")
      str << "</script>\n"
    end
  end
end
