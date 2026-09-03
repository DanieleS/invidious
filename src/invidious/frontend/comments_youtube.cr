module Invidious::Frontend::Comments
  extend self

  def template_youtube(comments, locale, thin_mode, is_replies = false)
    String.build do |html|
      root = comments["comments"].as_a
      root.each do |child|
        if child["replies"]?
          replies_count_text = I18n.translate_count(locale,
            "comments_view_x_replies",
            child["replies"]["replyCount"].as_i64 || 0,
            I18n::NumberFormatting::Separator
          )

          replies_html = <<-END_HTML
          <div id="replies" class="thread__replies">
            <a class="simulated_a" href="javascript:void(0)" data-continuation="#{child["replies"]["continuation"]}"
              data-onclick="get_youtube_replies" data-load-replies>#{replies_count_text}</a>
          </div>
          END_HTML
        elsif comments["authorId"]? && !comments["singlePost"]?
          # for posts we should display a link to the post
          replies_count_text = I18n.translate_count(locale,
            "comments_view_x_replies",
            child["replyCount"].as_i64 || 0,
            I18n::NumberFormatting::Separator
          )

          replies_html = <<-END_HTML
          <div class="thread__replies">
            <a href="/post/#{child["commentId"]}?ucid=#{comments["authorId"]}">#{replies_count_text}</a>
          </div>
          END_HTML
        end

        if !thin_mode
          if child_author_thumbnail = child["authorThumbnail"]?.try &.as_s
            author_thumbnail = "/ggpht#{URI.parse(child_author_thumbnail).request_target}"
          else
            author_thumbnail = "/ggpht#{URI.parse(child["authorThumbnails"][-1]["url"].as_s).request_target}"
          end
        else
          author_thumbnail = ""
        end

        author_name = HTML.escape(child["author"].as_s)
        sponsor_icon = ""
        if child["verified"]?.try &.as_bool && child["authorIsChannelOwner"]?.try &.as_bool
          author_name += " <svg class=\"verified\"><use href=\"#i-check\"/></svg>"
        elsif child["verified"]?.try &.as_bool
          author_name += " <svg class=\"verified\"><use href=\"#i-check\"/></svg>"
        end

        if child["isSponsor"]?.try &.as_bool
          sponsor_icon = String.build do |str|
            str << %(<img alt="" )
            str << %(src="/ggpht) << URI.parse(child["sponsorIconUrl"].as_s).request_target << "\" "
            str << %(title=") << I18n.translate(locale, "Channel Sponsor") << "\" "
            str << %(width="16" height="16" />)
          end
        end
        html << <<-END_HTML
        <div class="thread#{child["authorIsChannelOwner"] == true ? " thread--owner" : ""}">
          <img class="avatar avatar--40" loading="lazy" src="#{author_thumbnail}" alt="" />
          <div class="thread__body">
            <p class="thread__who">
              <b><a href="#{child["authorUrl"]}">#{author_name}</a></b>
              #{sponsor_icon}
            </p>
            <div class="thread__text" style="white-space:pre-wrap">#{child["contentHtml"]}</div>
        END_HTML

        if child["attachment"]?
          attachment = child["attachment"]

          case attachment["type"]
          when "image"
            attachment = attachment["imageThumbnails"][1]

            html << <<-END_HTML
            <div class="thread__attachment">
              <img loading="lazy" src="/ggpht#{URI.parse(attachment["url"].as_s).request_target}" alt="" />
            </div>
            END_HTML
          when "video"
            if attachment["error"]?
              html << <<-END_HTML
              <div class="video-iframe-wrapper">
                <p>#{attachment["error"]}</p>
              </div>
              END_HTML
            else
              html << <<-END_HTML
              <div class="video-iframe-wrapper">
                <iframe class="video-iframe" src='/embed/#{attachment["videoId"]?}?autoplay=0'></iframe>
              </div>
              END_HTML
            end
          when "multiImage"
            html << <<-END_HTML
              <section class="carousel">
              <a class="skip-link" href="#skip-#{child["commentId"]}">#{I18n.translate(locale, "carousel_skip")}</a>
              <div class="slides">
              END_HTML
            image_array = attachment["images"].as_a

            image_array.each_index do |i|
              html << <<-END_HTML
                  <div class="slides-item slide-#{i + 1}" id="#{child["commentId"]}-slide-#{i + 1}" aria-label="#{I18n.translate(locale, "carousel_slide", {"current" => (i + 1).to_s, "total" => image_array.size.to_s})}" tabindex="0">
                    <img loading="lazy" src="/ggpht#{URI.parse(image_array[i][1]["url"].as_s).request_target}" alt="" />
                  </div>
                END_HTML
            end

            html << <<-END_HTML
              </div>
              <div class="carousel__nav">
              END_HTML
            attachment["images"].as_a.each_index do |i|
              html << <<-END_HTML
                  <a class="slider-nav" href="##{child["commentId"]}-slide-#{i + 1}" aria-label="#{I18n.translate(locale, "carousel_go_to", (i + 1).to_s)}" tabindex="-1" aria-hidden="true">#{i + 1}</a>
                END_HTML
            end
            html << <<-END_HTML
              </div>
              <div id="skip-#{child["commentId"]}"></div>
            </section>
            END_HTML
          else nil # Ignore
          end
        end

        html << <<-END_HTML
        <p class="thread__acts">
          <span title="#{Time.unix(child["published"].as_i64).to_s(I18n.translate(locale, "%A %B %-d, %Y"))}">#{I18n.translate(locale, "`x` ago", recode_date(Time.unix(child["published"].as_i64), locale))} #{child["isEdited"] == true ? I18n.translate(locale, "(edited)") : ""}</span>
          |
        END_HTML

        if comments["videoId"]?
          html << <<-END_HTML
            <a rel="noreferrer noopener" href="https://www.youtube.com/watch?v=#{comments["videoId"]}&lc=#{child["commentId"]}" title="#{I18n.translate(locale, "YouTube comment permalink")}">[YT]</a>
            |
          END_HTML
        elsif comments["authorId"]?
          html << <<-END_HTML
            <a rel="noreferrer noopener" href="https://www.youtube.com/channel/#{comments["authorId"]}/community?lb=#{child["commentId"]}" title="#{I18n.translate(locale, "YouTube comment permalink")}">[YT]</a>
            |
          END_HTML
        end

        html << <<-END_HTML
          <span><svg class="icon icon--sm"><use href="#i-thumbup"/></svg> #{number_with_separator(child["likeCount"])}</span>
        END_HTML

        if child["creatorHeart"]?
          if !thin_mode
            creator_thumbnail = "/ggpht#{URI.parse(child["creatorHeart"]["creatorThumbnail"].as_s).request_target}"
          else
            creator_thumbnail = ""
          end

          html << <<-END_HTML
            &nbsp;
            <span class="creator-heart-container" title="#{I18n.translate(locale, "`x` marked it with a ❤", child["creatorHeart"]["creatorName"].as_s)}">
                <span class="creator-heart">
                    <img loading="lazy" class="creator-heart-background-hearted" src="#{creator_thumbnail}" alt="" />
                    <span class="creator-heart-small-hearted">
                        <svg class="icon icon--sm creator-heart-small-container"><use href="#i-heart"/></svg>
                    </span>
                </span>
            </span>
          END_HTML
        end

        html << <<-END_HTML
            </p>
            #{replies_html}
          </div>
        </div>
        END_HTML
      end

      if comments["continuation"]?
        html << <<-END_HTML
        <div class="thread__more">
          <button class="btn" type="button" data-continuation="#{comments["continuation"]}"
            data-onclick="get_youtube_replies" data-load-more #{"data-load-replies" if is_replies}>#{I18n.translate(locale, "Load more")}</button>
        </div>
        END_HTML
      end
    end
  end
end
