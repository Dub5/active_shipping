module ActiveShipping
  class DHL < Carrier

    cattr_reader :name
    @@name = "DHL"

    TEST_URL = 'http://xmlpitest-ea.dhl.com/XMLShippingServlet'

    def initialize(options)
      super
    end

    def requirements
      [:login, :password]
    end

    def find_rates(origin, destination, package = nil, options = {})
      rate_request = build_rate_request(origin, destination, package, options)
      response = ssl_post(TEST_URL, rate_request)
      parse_rates_response(response, origin, destination)
    rescue ActiveUtils::ResponseError, ActiveShipping::ResponseError => e
      error_response(e.response.body, DHLRateResponse)
    end

    def create_shipment(origin, destination, package, package_items, options = {})
      request_body = build_shipment_request(origin, destination, package, package_items, options)
      response = ssl_post(TEST_URL, request_body)
      parse_shipment_response(response)
    rescue ActiveUtils::ResponseError, ActiveShipping::ResponseError => e
      error_response(e.response.body, DHLShippingResponse)
    end

    def cancel_shipment

    end

    def find_tracking_info

    end

    def build_shipment_request(origin, destination, package, package_items, options = {})
      builder = Nokogiri::XML::Builder.new do |xml|
        xml.ShipmentRequest('xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'xsi:schemaLocation' => 'http://www.dhl.com ship-val-global-req.xsd', 'schemaVersion' => '5.0') do
          build_request_header(xml)
          xml.RegionCode(options[:region_code])
          xml.NewShipper(options[:new_shipper])
          xml.LanguageCode('ES')
          xml.PiecesEnabled('Y')
          xml.Billing do
            xml.ShipperAccountNumber(@options[:customer_number])
            xml.ShippingPaymentType('S')
            xml.DutyPaymentType('S') if options[:is_dutiable]
            xml.DutyAccountNumber(@options[:customer_number]) if options[:is_dutiable]
          end
          build_consignee_info(xml, destination)
          xml.Dutiable do
            xml.DeclaredValue(package.value)
            xml.DeclaredCurrency(@options[:currency])
          end
          xml.ShipmentDetails do
            xml.NumberOfPieces(1)
            xml.Pieces do
              xml.Piece do
                xml.PieceID(1)
                xml.Weight(package.kilograms)
              end
            end
            xml.Weight(package.kilograms)
            xml.WeightUnit('K')
            xml.GlobalProductCode(options[:service])
            xml.Date((DateTime.now.in_time_zone('America/Hermosillo') + 1.day).strftime('%Y-%m-%d'))
            xml.Contents(options[:content])
            xml.DimensionUnit('C')
            xml.CurrencyCode(@options[:currency])
          end
          build_shipper_info(xml, origin)
          xml.Notification do
            xml.EmailAddress('luis@dub5.com')
            xml.Message('Shipment validated')
          end
          xml.LabelImageFormat('PDF')
          xml.parent.namespace = xml.parent.add_namespace_definition('req', 'http://www.dhl.com')
        end
      end
      builder.to_xml
    end

    def build_rate_request(origin, destination, package = nil, options = {})
      xml_builder = Nokogiri::XML::Builder.new do |xml|
        xml.DCTRequest('xmlns:p1' => 'http://www.dhl.com/datatypes', 'xmlns:p2' => 'http://www.dhl.com/DCTRequestdatatypes', 'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'xsi:schemaLocation' => 'http://www.dhl.com DCT-req.xsd') do
          xml.GetQuote do
            build_request_header(xml)

            xml.From do
              xml.CountryCode(origin.country_code)
              xml.Postalcode(origin.postal_code)
              xml.City(origin.city)
            end

            build_booking_details(xml, package, options)

            xml.To do
              xml.CountryCode(destination.country_code)
              xml.Postalcode(destination.postal_code)
              xml.City(destination.city)
              xml.Suburb(destination.address2)
            end
          end
          xml.parent.namespace = xml.parent.add_namespace_definition('p', 'http://www.dhl.com')
        end
      end
      xml_builder.to_xml
    end

    def parse_rates_response(response, origin, destination)
      doc = Nokogiri.XML(response)
      doc.remove_namespaces!
      raise ActiveShipping::ResponseError, "No Quotes" unless doc.at('GetQuoteResponse')
      nodeset = doc.root.xpath('GetQuoteResponse').xpath('BkgDetails').xpath('QtdShp')
      rates = nodeset.map do |node|
        if node.at('CurrencyCode') != @options[:currency]
          currency_exchange = node.search('QtdSInAdCur').select { |node| node.at('CurrencyCode') && node.at('CurrencyCode').text == @options[:currency] }.first
          total_price   = currency_exchange.at('TotalAmount').text
        else
          total_price   = node.at('ShippingCharge').text
        end
        # next unless node.at('ShippingCharge').text.to_i > 0
        service_name  = node.at('ProductShortName').text
        service_code  = node.at("GlobalProductCode").text

        # expected_date = expected_date_from_node(node)
        options = {
          service_name: service_name,
          service_code: service_code,
          currency: @options[:currency],
          total_price: total_price,
        }
        ActiveShipping::RateEstimate.new(origin, destination, @@name, service_name, options)
      end
      rates.delete_if { |rate| rate.nil? }
      DHLRateResponse.new(true, "", {}, :rates => rates)
    end

    def parse_shipment_response(response)
      doc = Nokogiri.XML(response)
      doc.remove_namespaces!
      raise ActiveShipping::ResponseError, 'No Shipping' unless doc.at('ShipmentResponse')
      nodeset = doc.root.xpath('ShipmentResponse')
      options = {
        :tracking_number => doc.root.at('AirwayBillNumber').text,
        :label           => doc.root.at('LabelImage').at('OutputImage').text,
      }

      DHLShippingResponse.new(true, "", {}, options)
    end

    private

    def build_request_header(xml)
      xml.Request do
        xml.ServiceHeader do
          xml.MessageTime(DateTime.now)
          xml.MessageReference(@options[:reference]) if @options[:reference]
          xml.SiteID(@options[:login])
          xml.Password(@options[:password])
        end
      end
    end

    def build_booking_details(xml, package, options)
      xml.BkgDetails do
        xml.PaymentCountryCode('MX')
        xml.Date((DateTime.now.in_time_zone('America/Hermosillo') + 1.day).strftime('%Y-%m-%d'))
        xml.ReadyTime('PT24H00M')
        xml.DimensionUnit('CM')
        xml.WeightUnit('KG')
        xml.NumberOfPieces(1)
        xml.ShipmentWeight(package.kilograms.to_f)
        xml.PaymentAccountNumber(@options[:customer_number]) if @options[:customer_number]
        xml.IsDutiable(options[:is_dutiable])
      end
    end

    def build_consignee_info(xml, destination)
      xml.Consignee do
        xml.CompanyName(destination.name)
        xml.AddressLine(destination.address1)
        xml.City(destination.city)
        xml.Division(destination.state)
        xml.PostalCode(destination.postal_code)
        xml.CountryCode(destination.country_code)
        xml.CountryName(destination.country)
        xml.Contact do
          xml.PersonName(destination.name)
          xml.PhoneNumber(destination.phone)
        end
        xml.Suburb(destination.address2)
      end
    end

    def build_shipper_info(xml, origin)
      xml.Shipper do
        xml.ShipperID(@options[:customer_number])
        xml.CompanyName(origin.company_name)
        xml.RegisteredAccount(@options[:customer_number])
        xml.AddressLine(origin.address1)
        xml.City(origin.city)
        xml.Division(origin.state)
        xml.PostalCode(origin.postal_code)
        xml.CountryCode(origin.country_code)
        xml.CountryName(origin.country)
        xml.Contact do
          xml.PersonName(origin.name)
          xml.PhoneNumber(origin.phone)
        end
        xml.Suburb(origin.address2)
      end
    end

  end

  module DHLErrorResponse
    attr_accessor :error_code
    def handle_error(message, options)
      @error_code = options[:code]
    end
  end

  class DHLShippingResponse < ShippingResponse
    include DHLErrorResponse
    attr_reader :label
    def initialize(success, message, params = {}, options = {})
      handle_error(message, options)
      super
      @label = options[:label]
    end
  end

  class DHLRateResponse < RateResponse
    include DHLErrorResponse

    def initialize(success, message, params = {}, options = {})
      handle_error(message, options)
      super
    end
  end

  class MissingAccountNumberError < StandardError; end
end
