require "uri"

module Invidious::Frontend::Pagination
  extend self

  private def first_page(str : String::Builder, locale : String?, url : String)
    str << %(<a href=") << url << %(" class="btn">)

    if I18n.locale_is_rtl?(locale)
      # Inverted arrow ("first" points to the right)
      str << I18n.translate(locale, "First page")
      str << %(<svg class="icon icon--sm"><use href="#i-chev-r"/></svg>)
    else
      # Regular arrow ("first" points to the left)
      str << %(<svg class="icon icon--sm"><use href="#i-chev-l"/></svg>)
      str << I18n.translate(locale, "First page")
    end

    str << "</a>"
  end

  private def previous_page(str : String::Builder, locale : String?, url : String)
    # Link
    str << %(<a href=") << url << %(" class="btn">)

    if I18n.locale_is_rtl?(locale)
      # Inverted arrow ("previous" points to the right)
      str << I18n.translate(locale, "Previous page")
      str << %(<svg class="icon icon--sm"><use href="#i-chev-r"/></svg>)
    else
      # Regular arrow ("previous" points to the left)
      str << %(<svg class="icon icon--sm"><use href="#i-chev-l"/></svg>)
      str << I18n.translate(locale, "Previous page")
    end

    str << "</a>"
  end

  private def next_page(str : String::Builder, locale : String?, url : String)
    # Link
    str << %(<a href=") << url << %(" class="btn">)

    if I18n.locale_is_rtl?(locale)
      # Inverted arrow ("next" points to the left)
      str << %(<svg class="icon icon--sm"><use href="#i-chev-l"/></svg>)
      str << I18n.translate(locale, "Next page")
    else
      # Regular arrow ("next" points to the right)
      str << I18n.translate(locale, "Next page")
      str << %(<svg class="icon icon--sm"><use href="#i-chev-r"/></svg>)
    end

    str << "</a>"
  end

  def nav_numeric(locale : String?, *, base_url : String | URI, current_page : Int, show_next : Bool = true)
    return String.build do |str|
      str << %(<div class="pagination">\n)

      str << %(<div class="page-prev-container">)

      if current_page > 1
        params_prev = URI::Params{"page" => (current_page - 1).to_s}
        url_prev = HttpServer::Utils.add_params_to_url(base_url, params_prev)

        self.previous_page(str, locale, url_prev.to_s)
      end

      str << %(</div>\n)
      str << %(<div class="page-next-container">)

      if show_next
        params_next = URI::Params{"page" => (current_page + 1).to_s}
        url_next = HttpServer::Utils.add_params_to_url(base_url, params_next)

        self.next_page(str, locale, url_next.to_s)
      end

      str << %(</div>\n)

      str << %(</div>\n\n)
    end
  end

  def nav_ctoken(locale : String?, *, base_url : String | URI, ctoken : String?, first_page : Bool, params : URI::Params)
    return String.build do |str|
      str << %(<div class="pagination">\n)

      str << %(<div class="page-prev-container">)

      if !first_page
        self.first_page(str, locale, base_url.to_s)
      end

      str << %(</div>\n)

      str << %(<div class="page-next-container">)

      if !ctoken.nil?
        params["continuation"] = ctoken
        url_next = HttpServer::Utils.add_params_to_url(base_url, params)

        self.next_page(str, locale, url_next.to_s)
      end

      str << %(</div>\n)

      str << %(</div>\n\n)
    end
  end
end
