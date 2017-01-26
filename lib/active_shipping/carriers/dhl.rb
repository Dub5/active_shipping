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

    def create_shipment(origin, destination, package, options = {})
      request_body = build_shipment_request(origin, destination, package, line_items, options)
      response = ssl_post(TEST_URL, request_body, headers(options))
      parse_shipment_response(response)
    rescue ActiveUtils::ResponseError, ActiveShipping::ResponseError => e
      error_response(e.response.body, CPPWSShippingResponse)
    rescue MissingCustomerNumberError
      CPPWSShippingResponse.new(false, "Missing Customer Number", {}, :carrier => @@name)
    end

    def cancel_shipment

    end

    def find_tracking_info

    end

    def build_shipment_request(origin, destination, package, options = {})
      builder = Nokogiri::XML::Builder.new do |xml|
        xml.ShipmentRequest('xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'xsi:schemaLocation' => 'http://www.dhl.com ship-val-global-req.xsd', 'schemaVersion' => '5.0') do
          xml.Request do
            build_request_header(xml)

            # xml.RegionCode('')
            xml.LanguageCode('ES')
            xml.PiecesEnabled('Y')
            xml.Billing do
              xml.ShipperAccountNumber('')
              xml.ShippingPaymentType('')
            end

            xml.Consignee do
            end

            xml.ShipmentDetails do
            end

            xml.Shipper do
            end

            xml.Notification('luis@dub5.com')
          end
          xml.parent.namespace = xml.parent.add_namespace_definition('req', 'http://www.dhl.com')
        end
      end
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

            build_booking_details(xml, package)

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
        if node.at('CurrencyCode') != 'MXN'
          currency_exchange = node.search('QtdSInAdCur').select { |node| node.at('CurrencyCode') && node.at('CurrencyCode').text == 'MXN' }.first
          total_price   = currency_exchange.at('TotalAmount').text
        else
          total_price   = node.at('ShippingCharge').text
        end
        next unless node.at('ShippingCharge').text.to_i > 0
        service_name  = node.at('ProductShortName').text
        service_code  = node.at("GlobalProductCode").text

        # expected_date = expected_date_from_node(node)
        options = {
          service_name: service_name,
          service_code: service_code,
          currency: 'MXN',
          total_price: total_price,
        }
        ActiveShipping::RateEstimate.new(origin, destination, @@name, service_name, options)
      end
      rates.delete_if { |rate| rate.nil? }
      DHLRateResponse.new(true, "", {}, :rates => rates)
    end

    def build_request_header(xml)
      xml.Request do
        xml.ServiceHeader do
          xml.MessageTime(DateTime.now)
          xml.SiteID(@options[:login])
          xml.Password(@options[:password])
        end
      end
    end

    def build_booking_details(xml, package)
      xml.BkgDetails do
        xml.PaymentCountryCode('MX')
        xml.Date((DateTime.now.in_time_zone('America/Hermosillo') + 1.day).strftime('%Y-%m-%d'))
        xml.ReadyTime('PT24H00M')
        xml.DimensionUnit('CM')
        xml.WeightUnit('KG')
        xml.NumberOfPieces(1)
        xml.ShipmentWeight(package.kilograms.to_f)
        xml.IsDutiable('N')
      end
    end



  end

  module DHLErrorResponse
    attr_accessor :error_code
    def handle_error(message, options)
      @error_code = options[:code]
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
