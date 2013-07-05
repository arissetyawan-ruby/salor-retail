# coding: UTF-8

# Salor -- The innovative Point Of Sales Software for your Retail Store
# Copyright (C) 2012-2013  Red (E) Tools LTD
# 
# See license.txt for the license applying to all files within this software.


class ItemsController < ApplicationController
  before_filter :check_role, :except => [:info, :search]
  

  def index
    CashRegister.update_all_devicenodes
    orderby = "id DESC"
    orderby ||= params[:order_by]
    @items = @current_vendor.items.by_keywords(params[:keywords]).visible.where("items.sku NOT LIKE 'DMY%'").page(params[:page]).per(@current_vendor.pagination).order(orderby)
  end

  def show
    if params[:keywords] then
      @item = @current_vendor.items.visible.by_keywords(params[:keywords]).first
    end

    @item ||= @current_vendor.items.visible.find_by_id(params[:id])

    redirect_to items_path if not @item
    
    @from, @to = assign_from_to(params)
    @from = @from ? @from.beginning_of_day : 1.month.ago.beginning_of_day
    @to = @to ? @to.end_of_day : DateTime.now
    @sold_times = @current_vendor.order_items.visible.where(:sku => @item.sku, :is_buyback => nil, :refunded => nil, :created_at => @from..@to).collect do |i| 
      (i.order.paid and not i.order.is_proforma) ? i.quantity : 0 
    end.sum
  end

  def new
    @item = @current_vendor.items.build
  end

  def edit
    @item = @current_vendor.items.visible.where(["id = ? or sku = ?",params[:id],params[:keywords]]).first
    #@item.item_stocks.build if not @item.item_stocks.any?
    #@item.item_shippers.build if not @item.item_shippers.any?
  end


  def create
    @item = Item.new(params[:item])
    @item.vendor = @current_vendor
    @item.company = @current_company
    if @item.save
      @item.assign_parts(params[:part_skus])
      redirect_to items_path
    else
      render :new
    end
  end
  
  # from shipment form
  def create_ajax
    @item = Item.new
    @item.vendor = @current_vendor
    @item.company = @current_company
    @item.item_type = @current_vendor.item_types.find_by_behavior("normal")
    @item.tax_profile_id = params[:item][:tax_profile_id]
    @item.attributes = params[:item]
    @item.save
    render :nothing => true
  end

  def update
    @item = @current_vendor.items.visible.find_by_id(params[:id])
    if @item.update_attributes(params[:item])
      @item.assign_parts(params[:part_skus])
      redirect_to items_path
    else
      render :edit
    end
  end
  
  
  def update_real_quantity
    add_breadcrumb I18n.t("menu.update_real_quantity"), items_update_real_quantity_path
    if request.post? then
      @item = Item.scopied.find_by_sku(params[:sku])
      @item.update_attribute(:real_quantity, params[:quantity])
      @item.update_attribute(:real_quantity_updated, true)
    end
  end
  def move_real_quantity
    ir = InventoryReport.create(:name => "AutoGenerated #{Time.now}", :created_at => Time.now, :updated_at => Time.now, :vendor_id => @current_user.vendor_id)
    sql = %Q[
        insert into inventory_report_items 
        ( inventory_report_id,
          item_id,
          real_quantity,
          item_quantity,
          created_at,
          updated_at,
          vendor_id
         ) select 
            ir.id,
            i.id,
            i.real_quantity,
            i.quantity,
            NOW(),
            NOW(),
            ir.vendor_id from 
          items as i, 
          inventory_reports as ir where 
            i.real_quantity_updated IS TRUE and 
            ir.id = #{ir.id}
  ]
    Item.connection.execute(sql)
    Item.connection.execute("update items set quantity = real_quantity, real_quantity_updated = FALSE where real_quantity_updated IS TRUE")
    redirect_to items_update_real_quantity_path, :notice => t('views.notice.move_real_quantities_success')
  end

  def destroy
    @item = Item.find_by_id(params[:id])
    if @current_user.owns_this?(@item) then
      if @item.order_items.any? then
        @item.update_attribute(:hidden,1)
        @item.update_attribute(:sku, rand(999).to_s + 'OLD:' + @item.sku)
      else
        @item.destroy
      end
    end
  end
  
  def info
    if params[:sku] then
      @item = Item.find_by_sku(params[:sku])
    else
      @item = Item.find(params[:id]) if Item.exists? params[:id]
    end
  end

  def search
    if not @current_user.owns_vendor? @current_user.vendor_id then
      @current_user.vendor_id = salor_user.get_default_vendor.id
    end
    @items = []
    @customers = []
    @orders = []
    if params[:klass] == 'Item' then
      @items = Item.scopied.page(params[:page]).per($Conf.pagination)
    elsif params[:klass] == 'Order'
      if params[:keywords].empty? then
        @orders = Order.by_vendor.by_user.order("id DESC").page(params[:page]).per($Conf.pagination)
      else
        @orders = Order.by_vendor.by_user.where("id = '#{params[:keywords]}' or nr = '#{params[:keywords]}' or tag LIKE '%#{params[:keywords]}%'").page(params[:page]).per($Conf.pagination)
      end
    else
      @customers = Customer.scopied.page(params[:page]).per($Conf.pagination)
    end
  end
  
  def item_json
    @item = @current_vendor.items.visible.find_by_sku(params[:sku], :select => "name,sku,id,purchase_price")
  end
  
  def edit_location
    respond_to do |format|
      format.html 
      format.js { render :content_type => 'text/javascript',:layout => false}
    end
  end

  def labels
    if params[:id]
      @items = @current_vendor.items.existing.where(:id => params[:id])
    elsif params[:skus]
      # text has been entered on the items#selection scren
      match = /(ORDER)(.*)/.match(params[:skus].split(",").first)
      if match and match[1] == 'ORDER'
        # print labels from all OrderItems of that Order
        order_id = match[2].to_i
        @order_items = @current_vendor.orders.find_by_id(order_id).order_items.visible
        @items = []
      else
        # print only the entered SKUs
        @order_items = []
        skus = params[:skus].split(",")
        @items = @current_vendor.items.visible.where(:sku => skus)
      end
    end
    
    @currency = I18n.t('number.currency.format.friendly_unit')
    template = File.read("#{Rails.root}/app/views/printr/#{params[:type]}_#{params[:style]}.prnt.erb")
    erb = ERB.new(template, 0, '>')
    text = erb.result(binding)
      
    if params[:download] == 'true'
      send_data Escper::Asciifier.new.process(text), :filename => '1.salor' and return
    elsif @current_register.salor_printer
      render :text => Escper::Asciifier.new.process(text) and return
    else
      if params[:type] == 'sticker'
        printer_path = @current_register.sticker_printer
      else
        printer_path = @current_register.thermal_printer
      end
      printerconfig = {
        :id => 0,
        :name => @current_register.name,
        :path => printer_path,
        :copied => 1,
        :codepage => 0,
        :baudrate => 9600
      }
      print_engine = Escper::Printer.new('local', printerconfig)
      print_engine.open
      print_engine.print(0, text)
      print_engine.close
      render :nothing => true and return
    end
  end

  def database_distiller
    @all_items = Item.where(:hidden => 0).count
    @used_item_ids = OrderItem.connection.execute('select item_id from order_items').to_a.flatten.uniq
    @hidden = Item.where('hidden = 1')
    @hidden_by_distiller = Item.where('hidden_by_distiller = 1')
  end

  def distill_database
    all_item_ids = Item.connection.execute('select id from items').to_a.flatten.uniq
    used_item_ids = OrderItem.connection.execute('select item_id from order_items').to_a.flatten.uniq
    deletion_item_ids = all_item_ids - used_item_ids
    Item.where(:id => deletion_item_ids).update_all(:hidden => 1, :hidden_by_distiller => true, :child_id => nil, :sku => nil)
    redirect_to '/items/database_distiller'
  end
  
  def reorder_recommendation
    text = Item.recommend_reorder(params[:type])
    if not text.nil? and not text.empty? then
      send_data text,:filename => "Reorder" + Time.now.strftime("%Y%m%d%H%I") + ".csv", :type => "application/x-csv"
    else
      redirect_to :action => :index, :notice => I18n.t("system.errors.cannot_reorder")
    end
    
  end

  def upload
    if params[:file]
      @uploader = FileUpload.new("salorretail", @current_vendor, params[:file].read)
      @uploader.crunch
    end
  end
# 
#   def upload_danczek_tobaccoland_plattner
#     if params[:file]
#       lines = params[:file].read.split("\n")
#       i, updated_items, created_items, created_categories, created_tax_profiles = FileUpload.new.type1("tobaccoland", lines)
#       redirect_to(:action => 'index')
#     end
#   end
# 
#   def upload_house_of_smoke
#     if params[:file]
#       lines = params[:file].read.split("\n")
#       i, updated_items, created_items, created_categories, created_tax_profiles = FileUpload.new.type2("dios", lines)
#       redirect_to(:action => 'index')
#     end
#   end
# 
#   def upload_optimalsoft
#     if params[:file]
#       lines = params[:file].read.split("\n")
#       i, updated_items, created_items, created_categories, created_tax_profiles = FileUpload.new.type3("Optimalsoft", lines)
#       redirect_to(:action => 'index')
#     end
#   end
  
  def download
    params[:page] ||= 1
    params[:order_by] ||= "created_at"
    params[:order_by] = "created_at" if not params[:order_by] or params[:order_by].blank?
    if params[:order_by] then
      key = params[:order_by]
      session[key] ||= 'ASC'
      @items = Item.scopied.where("items.sku NOT LIKE 'DMY%'").page(params[:page]).per($Conf.pagination).order("#{key} #{session[key]}")
    else
      @items = Item.scopied.where("items.sku NOT LIKE 'DMY%'").page(params[:page]).per($Conf.pagination).order("id desc")
    end
    data = render_to_string :layout => false
    send_data(data,:filename => 'items.csv', :type => 'text/csv')
  end

  def inventory_report
    add_breadcrumb I18n.t("menu.update_real_quantity"), items_update_real_quantity_path
    add_breadcrumb I18n.t("menu.inventory_report"), items_inventory_report_path
    @items = Item.scopied.where(:real_quantity_updated => true)
    @categories = Category.scopied
  end
  
  def selection
    if params[:order_id]
      order = @current_vendor.orders.visible.find_by_id(params[:order_id])
      @skus = "ORDER#{order.id}"
    else
      @skus = nil
    end
  end
  
  def report
    @items = @current_vendor.items.select("items.quantity,items.name,items.sku,items.base_price,items.category_id,items.location_id,items.id,items.vendor_id").visible.includes(:location,:category).by_keywords.page(params[:page]).per(100)
    @view = SalorRetail::Application::CONFIGURATION[:reports][:style]
    @view ||= 'default'
    render "items/reports/#{@view}/page"
  end

  def new_action
    item = @current_vendor.items.visible.find_by_id(params[:item_id])
    action = item.create_action
    redirect_to action_path(action)
  end
end
