require 'bookmeter_scraper/bookmeter'

module BookmeterScraper
  class Scraper
    PROFILE_ATTRIBUTES = %i(name
                            gender
                            age
                            blood_type
                            job
                            address
                            url
                            description
                            first_day
                            elapsed_days
                            read_books_count
                            read_pages_count
                            reviews_count
                            bookshelfs_count)
    Profile = Struct.new(*PROFILE_ATTRIBUTES)

    JP_ATTRIBUTE_NAMES = {
      gender: '性別',
      age: '年齢',
      blood_type: '血液型',
      job: '職業',
      address: '現住所',
      url: 'URL / ブログ',
      description: '自己紹介',
      first_day: '記録初日',
      elapsed_days: '経過日数',
      read_books_count: '読んだ本',
      read_pages_count: '読んだページ',
      reviews_count: '感想/レビュー',
      bookshelfs_count: '本棚',
    }

    BOOK_ATTRIBUTES = %i(name author read_dates uri image_uri)
    Book = Struct.new(*BOOK_ATTRIBUTES)
    class Books
      extend Forwardable

      def_delegator :@books, :[]
      def_delegator :@books, :[]=
      def_delegator :@books, :<<
      def_delegator :@books, :each
      def_delegator :@books, :flatten!

      def initialize; @books = []; end

      def concat(books)
        books.each do |book|
          next if @books.any? { |b| b.name == book.name && b.author == book.author }
          @books << book
        end
      end

      def to_a; @books; end
    end

    USER_ATTRIBUTES = %i(name id uri)
    User = Struct.new(*USER_ATTRIBUTES)

    NUM_BOOKS_PER_PAGE = 40
    NUM_USERS_PER_PAGE = 20


    def initialize(agent = nil)
      @agent = agent
      @book_pages = {}
    end

    def get_book_structs(page)
      books = []

      1.upto(NUM_BOOKS_PER_PAGE) do |i|
        break if page["book_#{i}_link"].empty?

        read_dates = []
        read_date = get_read_date(page["book_#{i}_link"])
        unless read_date.empty?
          read_dates << Time.local(read_date['year'], read_date['month'], read_date['day'])
        end

        reread_dates = []
        reread_dates << get_reread_date(page["book_#{i}_link"])
        reread_dates.flatten!

        unless reread_dates.empty?
          reread_dates.each do |date|
            read_dates << Time.local(date['reread_year'], date['reread_month'], date['reread_day'])
          end
        end

        book_path = page["book_#{i}_link"]
        book_name = get_book_name(book_path)
        book_author = get_book_author(book_path)
        book_image_uri = get_book_image_uri(book_path)
        book = Book.new(book_name,
                        book_author,
                        read_dates,
                        ROOT_URI + book_path,
                        book_image_uri)
        books << book
      end

      books
    end

    def get_followings(user_id, agent = @agent)
      users = []
      scraped_pages = user_id == agent.log_in_user_id ? scrape_followings_page(user_id)
                                                      : scrape_others_followings_page(user_id)
      scraped_pages.each do |page|
        users << get_user_structs(page)
        users.flatten!
      end
      users
    end

    def get_followers(user_id)
      users = []
      scraped_pages = scrape_followers_page(user_id)
      scraped_pages.each do |page|
        users << get_user_structs(page)
        users.flatten!
      end
      users
    end

    def get_user_structs(page)
      users = []

      1.upto(NUM_USERS_PER_PAGE) do |i|
        break if page["user_#{i}_name"].empty?

        user_name = page["user_#{i}_name"]
        user_id = page["user_#{i}_link"].match(/\/u\/(\d+)$/)[1]
        user = User.new(user_name, user_id, ROOT_URI + "/u/#{user_id}")
        users << user
      end

      users
    end

    def get_books(user_id, uri_method)
      books = Books.new
      scraped_pages = scrape_book_pages(user_id, uri_method)
      scraped_pages.each do |page|
        books << get_book_structs(page)
        books.flatten!
      end
      books
    end

    def get_read_books(user_id, target_ym)
      result = Books.new
      scrape_book_pages(user_id, :read_books_uri).each do |page|
        first_book_date = get_read_date(page['book_1_link'])
        last_book_date  = get_last_book_date(page)

        first_book_ym = Time.local(first_book_date['year'].to_i, first_book_date['month'].to_i)
        last_book_ym  = Time.local(last_book_date['year'].to_i, last_book_date['month'].to_i)

        if target_ym < last_book_ym
          next
        elsif target_ym == first_book_ym && target_ym > last_book_ym
          result.concat(get_target_books(target_ym, page))
          break
        elsif target_ym < first_book_ym && target_ym > last_book_ym
          result.concat(get_target_books(target_ym, page))
          break
        elsif target_ym <= first_book_ym && target_ym >= last_book_ym
          result.concat(get_target_books(target_ym, page))
        elsif target_ym > first_book_ym
          break
        end
      end
      result
    end

    def get_last_book_date(page)
      NUM_BOOKS_PER_PAGE.downto(1) do |i|
        link = page["book_#{i}_link"]
        next if link.empty?
        return get_read_date(link)
      end
    end

    def get_target_books(target_ym, page)
      target_books = Books.new

      1.upto(NUM_BOOKS_PER_PAGE) do |i|
        next if page["book_#{i}_link"].empty?

        read_yms = []
        read_date = get_read_date(page["book_#{i}_link"])
        read_dates = [Time.local(read_date['year'], read_date['month'], read_date['day'])]
        read_yms << Time.local(read_date['year'], read_date['month'])

        reread_dates = []
        reread_dates << get_reread_date(page["book_#{i}_link"])
        reread_dates.flatten!

        unless reread_dates.empty?
          reread_dates.each do |date|
            read_yms << Time.local(date['reread_year'], date['reread_month'])
          end
        end

        next unless read_yms.include?(target_ym)

        unless reread_dates.empty?
          reread_dates.each do |date|
            read_dates << Time.local(date['reread_year'], date['reread_month'], date['reread_day'])
          end
        end
        book_path = page["book_#{i}_link"]
        book_name = get_book_name(book_path)
        book_author = get_book_author(book_path)
        book_image_uri = get_book_image_uri(book_path)
        book = Book.new(book_name, book_author, read_dates, ROOT_URI + book_path, book_image_uri)
        target_books << book
      end

      target_books
    end


    def profile(user_id, agent = @agent)
      raise ArgumentError unless user_id =~ USER_ID_REGEX
      raise BookmeterError if agent.nil?

      mypage = agent.get(BookmeterScraper.mypage_uri(user_id))

      profile_dl_tags = mypage.search('#side_left > div.inner > div.profile > dl')
      jp_attribute_names = profile_dl_tags.map { |i| i.children[0].children.text }
      attribute_values   = profile_dl_tags.map { |i| i.children[1].children.text }
      jp_attributes = Hash[jp_attribute_names.zip(attribute_values)]
      attributes = PROFILE_ATTRIBUTES.map do |attribute|
        jp_attributes[JP_ATTRIBUTE_NAMES[attribute]]
      end
      attributes[0] = mypage.at_css('#side_left > div.inner > h3').text

      Profile.new(*attributes)
    end

    def get_book_page(book_uri, agent = @agent)
      @book_pages[book_uri] = agent.get(ROOT_URI + book_uri) unless @book_pages[book_uri]
      @book_pages[book_uri]
    end

    def get_book_name(book_uri)
      get_book_page(book_uri).search('#title').text
    end

    def get_book_author(book_uri)
      get_book_page(book_uri).search('#author_name').text
    end

    def get_book_image_uri(book_uri)
      get_book_page(book_uri).search('//*[@id="book_image"]/@src').text
    end

    def scrape_book_pages(user_id, uri_method, agent = @agent)
      raise ArgumentError unless user_id =~ USER_ID_REGEX
      raise ArgumentError unless BookmeterScraper.methods.include?(uri_method)
      raise BookmeterError if agent.nil?
      return [] unless agent.logged_in?

      books_page = agent.get(BookmeterScraper.method(uri_method).call(user_id))

      # if books are not found at all
      return [] if books_page.search('#main_left > div > center > a').empty?

      if books_page.search('span.now_page').empty?
        books_root = Yasuri.struct_books '//*[@id="main_left"]/div' do
          1.upto(NUM_BOOKS_PER_PAGE) do |i|
            send("text_book_#{i}_name", "//*[@id=\"main_left\"]/div/div[#{i + 1}]/div[2]/a")
            send("text_book_#{i}_link", "//*[@id=\"main_left\"]/div/div[#{i + 1}]/div[2]/a/href")
          end
        end
        return [books_root.inject(agent, books_page)]
      end

      books_root = Yasuri.pages_root '//span[@class="now_page"]/following-sibling::span[1]/a' do
        text_page_index '//span[@class="now_page"]/a'
        1.upto(NUM_BOOKS_PER_PAGE) do |i|
          send("text_book_#{i}_name", "//*[@id=\"main_left\"]/div/div[#{i + 1}]/div[2]/a")
          send("text_book_#{i}_link", "//*[@id=\"main_left\"]/div/div[#{i + 1}]/div[2]/a/@href")
        end
      end
      books_root.inject(agent, books_page)
    end

    def get_read_date(book_uri, agent = @agent)
      book_date = Yasuri.struct_date '//*[@id="book_edit_area"]/form[1]/div[2]' do
        text_year  '//*[@id="read_date_y"]/option[1]', truncate: /\d+/, proc: :to_i
        text_month '//*[@id="read_date_m"]/option[1]', truncate: /\d+/, proc: :to_i
        text_day   '//*[@id="read_date_d"]/option[1]', truncate: /\d+/, proc: :to_i
      end
      book_date.inject(agent, get_book_page(book_uri))
    end

    def get_reread_date(book_uri, agent = @agent)
      book_reread_date = Yasuri.struct_reread_date '//*[@id="book_edit_area"]/div/form[1]/div[2]' do
        text_reread_year  '//div[@class="reread_box"]/form[1]/div[2]/select[1]/option[1]', truncate: /\d+/, proc: :to_i
        text_reread_month '//div[@class="reread_box"]/form[1]/div[2]/select[2]/option[1]', truncate: /\d+/, proc: :to_i
        text_reread_day   '//div[@class="reread_box"]/form[1]/div[2]/select[3]/option[1]', truncate: /\d+/, proc: :to_i
      end
      book_reread_date.inject(agent, get_book_page(book_uri))
    end

    def scrape_followings_page(user_id, agent = @agent)
      raise ArgumentError unless user_id =~ USER_ID_REGEX
      return [] unless agent.logged_in?

      followings_page = agent.get(BookmeterScraper.followings_uri(user_id))
      followings_root = Yasuri.struct_books '//*[@id="main_left"]/div' do
        1.upto(NUM_USERS_PER_PAGE) do |i|
          send("text_user_#{i}_name", "//*[@id=\"main_left\"]/div/div[#{i}]/a/@title")
          send("text_user_#{i}_link", "//*[@id=\"main_left\"]/div/div[#{i}]/a/@href")
        end
      end
      [followings_root.inject(agent, followings_page)]
    end

    def scrape_users_listing_page(user_id, uri_method, agent = @agent)
      raise ArgumentError unless user_id =~ USER_ID_REGEX
      raise ArgumentError unless BookmeterScraper.methods.include?(uri_method)
      return [] unless agent.logged_in?

      page = agent.get(BookmeterScraper.method(uri_method).call(user_id))
      root = Yasuri.struct_users '//*[@id="main_left"]/div' do
        1.upto(NUM_USERS_PER_PAGE) do |i|
          send("text_user_#{i}_name", "//*[@id=\"main_left\"]/div/div[#{i}]/div/div[2]/a/@title")
          send("text_user_#{i}_link", "//*[@id=\"main_left\"]/div/div[#{i}]/div/div[2]/a/@href")
        end
      end
      [root.inject(agent, page)]
    end

    def scrape_others_followings_page(user_id)
      scrape_users_listing_page(user_id, :followings_uri)
    end

    def scrape_followers_page(user_id)
      scrape_users_listing_page(user_id, :followers_uri)
    end
  end
end