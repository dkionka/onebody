class VersesController < ApplicationController
  def index
    Verse.destroy_all "(select count(*) from people_verses where verse_id = verses.id) = 0 and (select count(*) from events_verses where verse_id = verses.id) = 0" # clean up
    @pages = Paginator.new self, Verse.count, 25, params[:page]
    @verses = Verse.find :all,
      :order => 'book, chapter, verse',
      :select => '*, (select count(*) from people_verses where verse_id = verses.id) as people_count',
      :limit => @pages.items_per_page,
      :offset => @pages.current.offset
    biggest = Tag.find_by_sql("select count(tag_id) as num from tags_verses where verse_id is not null group by tag_id order by count(tag_id) desc limit 1").first.num.to_i rescue 0
    @factor = biggest / 11
    @factor = 1 if @factor.zero?
    @tags = Tag.find :all, :conditions => '(select count(*) from tags_verses where tag_id = tags.id and verse_id is not null) > 0', :order => 'name'
  end
  
  def view
    if params[:id] =~ /^\d+$/
      @verse = Verse.find params[:id]
    else
      @verse = Verse.find_by_reference params[:id]
    end
  end
  
  def add_tags
    @verse = Verse.find params[:id]
    @verse.tag_string = params[:tag_string]
    redirect_to :action => 'view', :id => @verse
  end
  
  def delete_tag
    @verse = Verse.find params[:id]
    @verse.tags.delete Tag.find(params[:tag_id])
    redirect_to :action => 'view', :id => @verse
  end

  def add_verse
    redirect_to params.merge({:controller => 'people'})
  end
end
