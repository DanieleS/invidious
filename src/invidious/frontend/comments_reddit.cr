module Invidious::Frontend::Comments
  extend self

  def template_reddit(root, locale)
    String.build do |html|
      root.each do |child|
        if child.data.is_a?(RedditComment)
          child = child.data.as(RedditComment)
          body_html = HTML.unescape(child.body_html)

          replies_html = ""
          if child.replies.is_a?(RedditThing)
            replies = child.replies.as(RedditThing)
            replies_html = self.template_reddit(replies.data.as(RedditListing).children, locale)
          end

          html << <<-END_HTML
          <div class="thread-reddit#{child.depth > 0 ? " thread-reddit--nested" : ""}">
            <p class="thread__who">
              <button class="simulated_a" type="button" data-onclick="toggle_parent">[ − ]</button>
              <b><a href="https://www.reddit.com/user/#{child.author}">#{child.author}</a></b>
              <span>#{I18n.translate_count(locale, "comments_points_count", child.score, I18n::NumberFormatting::Separator)}</span>
              <span title="#{child.created_utc.to_s("%a %B %-d %T %Y UTC")}">#{I18n.translate(locale, "`x` ago", recode_date(child.created_utc, locale))}</span>
              <a href="https://www.reddit.com#{child.permalink}" title="#{I18n.translate(locale, "permalink")}">#{I18n.translate(locale, "permalink")}</a>
            </p>
            <div class="thread__text">
            #{body_html}
            </div>
            #{replies_html}
          </div>
          END_HTML
        end
      end
    end
  end
end
