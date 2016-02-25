# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'erb'

#start the measure
class OTTVWithRTTV < OpenStudio::Ruleset::ReportingUserScript

  # human readable name
  def name
    return "OTTV with RTTV"
  end

  # human readable description
  def description
    return "This measure evaluates the envelope construction assemblies to report the Overall Thermal Transmittance Value (OTTV) for all conditioned spaces. The OTTV is indicative of the average rate of heat transfer into a building through the building envelope. The OTTV is a commonly applied metric in South East Asian countries for demonstrating code compliance. This measure specifically evaluates the envelope (excluding the roof) for compliance with the Malaysian Code 'MS 1525: 2001 Code of Practice on Energy efficiency and use of renewable energy for non-residential buildings'. 
Current version does not include shading surfaces for calculations. Update to the current version incorporating the effect of shades and roof is under development.
The measure provides calculations for 8 orientations (North, North East, East, etc). For facade orientation other than these 8, the measure applies the nearest orientation for calculations."
  end

  # human readable description of modeling approach
  def modeler_description
    return "This reporting measure reads surface details from the model to perform OTTV calculations. The measure filters out all thermal zones with 'thermostat' <OS_ThermalZone.thermostat()> and evaluates the 'wind exposed' surfaces <OS_Surface> and the 'sub-surfaces' <OS_SubSurface> contained within these spaces for OTTV calculations. Currently, the measure works for Simple Glazing <OS:WindowMaterial:SimpleGlazingSystem> type only."
  end

  # define the arguments that the user will input
  def arguments()
    args = OpenStudio::Ruleset::OSArgumentVector.new

    # this measure does not require any user arguments, return an empty list

    return args
  end 
  
  # return a vector of IdfObject's to request EnergyPlus objects needed by the run method
  def energyPlusOutputRequests(runner, user_arguments)
    super(runner, user_arguments)
    
    result = OpenStudio::IdfObjectVector.new
    
    # use the built-in error checking 
    if !runner.validateUserArguments(arguments(), user_arguments)
      return result
    end
    
    request = OpenStudio::IdfObject.load("Output:Variable,,Site Outdoor Air Drybulb Temperature,Hourly;").get
    result << request
    
    return result
  end
  
  
  
  #function to convert azimuth angle to orientation
  def azimuth_to_direction(azimuth,north_axis)
	azimuth = OpenStudio::Quantity.new(azimuth, OpenStudio::createSIAngle)				
	azimuth = OpenStudio.convert(azimuth, OpenStudio::createIPAngle).get.value  + north_axis
	while (azimuth > 360.0)
	    azimuth = azimuth - 360
	end
	if(azimuth >= 337.5 or azimuth < 22.5)
		facade = "North"
	
	elsif (azimuth >= 22.5 and azimuth < 67.5)
		facade = "North-East"
	
	elsif (azimuth >= 67.5 and azimuth < 112.5)
		facade = "East"
   
	elsif (azimuth >= 112.5 and azimuth < 157.5)
		facade = "South-East"
	
	elsif (azimuth >= 157.5 and azimuth < 202.5)
		facade = "South"
	
	elsif (azimuth >= 202.5 and azimuth < 247.5)
		facade = "South-West"
   
	elsif (azimuth >= 247.5 and azimuth < 292.5)
		facade = "West"
	elsif (azimuth >= 292.5 and azimuth < 337.5)
		facade = "North-West"
	end	
	return azimuth, facade
  end
  
  
  
  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # use the built-in error checking 
    if !runner.validateUserArguments(arguments(), user_arguments)
      return false
    end

    # get the last model and sql file
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError("Cannot find last model.")
      return false
    end
    model = model.get

    sqlFile = runner.lastEnergyPlusSqlFile
    if sqlFile.empty?
      runner.registerError("Cannot find last sql file.")
      return false
    end
    sqlFile = sqlFile.get
    model.setSqlFile(sqlFile)
	
	
	############ custom code starts #############
	
	
	### variable declaration####
	cf_summary = ""
	proj_summary = ""
	surface_ottv_summary = ""
	surface_summary = ""
	table_summary = ""
	north_axis = 0
	surface_details = []										#array for storing surface data for table_1
	ottv_wall = 0
	ottv_fenestration = 0
	ottv = 0
	surface_area_sum = 0
	ottv_area_multi_sum = 0
	surface_area_with_floor_sum = 0
	u_wall_sum = 0
	u_fenestration_sum = 0
	sc_sum = 0
	wall_ottv_sum = 0
	window_conduction_ottv_sum = 0
	window_solar_heat_gain_ottv_sum = 0	
	chart_str = ""
	
	#correction factor hash set
	cf = Hash["North" => 0.9, "South" => 0.92, "East" => 1.23, "West" => 0.94, "North-East" => 1.09, "South-East" => 1.13, "South-West" => 0.9, "North-West" => 0.9]
    
	
	sites=model.getSite
	weather_file=sites.weatherFile 
	
	if ( !model.getBuilding.isNorthAxisDefaulted )
			north_axis = model.getBuilding.northAxis.to_f
			#output << model.getBuilding.northAxis.to_s		     
	end
	
	#### generation project info table ########
	proj_summary << "<tr><td>Building Name</td><td>" << model.getBuilding.name.get << "</td></tr>"
	proj_summary << "<tr><td>Longitude</td><td>" << sites.longitude.to_s << "</td></tr>"
	proj_summary << "<tr><td>Latitude</td><td>" << sites.latitude.to_s << "</td></tr>"
	proj_summary << "<tr><td>City</td><td>" << weather_file.get.city.to_s << "</td></tr>"
	proj_summary << "<tr><td>Country</td><td>" << weather_file.get.country.to_s << "</td></tr>"
	proj_summary << "<tr><td>OTTV</td>"
	
	#get list of spaces in model
	spaces = model.getSpaces
	spaces.each do |space|   # space loop start
		#get thermal zone of space
		thermal_zones = space.thermalZone
		if ! thermal_zones.get.thermostat.empty?    		#if conditioned (if thermostat of thermal zone is empty = conditioned)
			multiplier = thermal_zones.get.multiplier				
			# getting all surface instance
			surfaces=space.surfaces
			surfaces.each do |surface|        # surface loop start
				#checking for wind exposed surface
				if 	surface.windExposure.to_s == "WindExposed" and surface.surfaceType == "Wall"
					# initializing local variable inside loop
					ottv_wall = 0
					ottv_fenestration_conductance = 0
					ottv_fenestration_shgc = 0					
					solar_absorptance = 0					
					subsurface_shgc = 0
					sub_surface_sc = 0
					ottv_fenestration = 0
					ottv = 0
					
					## getting surface values
					ext_wall_const = surface.construction.get
					exterior_surface_constructions = ext_wall_const.to_Construction.get
					construction_layers = exterior_surface_constructions.layers
					solar_absorptance = construction_layers[0].to_OpaqueMaterial.get.solarAbsorptance.to_f
					surface_space_name = surface.space.get.name.to_s
					surface_name = surface.name.to_s
					wwr = surface.windowToWallRatio.to_f
					uValue = surface.uFactor.to_f
					surface_grossArea = surface.grossArea.to_f
						
					## calculating wall OTTV
					surface_area_sum = surface_area_sum + surface_grossArea
					ottv_wall = 15 * solar_absorptance * (1 - wwr) * uValue 
					wall_ottv_sum = wall_ottv_sum + ottv_wall
						
					## surface wise OTTV summary table
					surface_ottv_summary <<  "<tr>"
					surface_ottv_summary << "<td> " << surface_space_name << "</td>"
					surface_ottv_summary << "<td> " << surface_name << "</td>"
					surface_ottv_summary << "<td class='rightalign'> " << surface_grossArea.round(2).to_s << "</td>"
					surface_ottv_summary << "<td class='rightalign'> " << solar_absorptance.round(2).to_s << "</td>"
					surface_ottv_summary << "<td class='rightalign'>" << wwr.round(2).to_s << "</td>"
					surface_ottv_summary << "<td class='rightalign' >" << uValue.round(2).to_s << "</td>"
						
					## collecting data for surafec details table
					azimuth,facade  = azimuth_to_direction(surface.azimuth,north_axis)
					surface_det = [surface.name.to_s, surface.surfaceType.to_s, surface.space.get.name.to_s, surface.construction.get.name.to_s, azimuth.round(1).to_s, facade]
					surface_details.push(surface_det)
					############
					
					cnt = 0
					# getting all subsurface of that surface
					sub_surfaces=surface.subSurfaces
					# subsurfaces loop start
					sub_surfaces.each do |sub_surface|	
						if sub_surface.subSurfaceType.to_s.include? "Window"
							cnt = cnt + 1 
							
							# get subsurface azimuth to determine facade
							azimuth, facade = azimuth_to_direction(sub_surface.azimuth,north_axis)
							
							orientation = facade
							subsurface_cf = 0
							cf.each do |key, value|       # cf loop start
								if ( key == orientation)
									subsurface_cf = value
									break
								end	
							end      # cf loop ends
			
							subsurface_shgc = 0
							# get shgc of sub surface
							sub_surface_const = sub_surface.construction.get
							exterior_sub_surface_construction = sub_surface_const.to_Construction.get
							construction_layers = exterior_sub_surface_construction.layers
							subsurface_cons_layer = construction_layers[0].to_SimpleGlazing  unless construction_layers[0].to_SimpleGlazing.empty?
							subsurface_cons_layer = construction_layers[0].to_StandardGlazing  unless construction_layers[0].to_StandardGlazing.empty?
							subsurface_shgc = subsurface_cons_layer.get.solarTransmittance 
							
							# getting values for sub surface
							sub_surface_sc = subsurface_shgc / 0.87
							sub_surface_name = sub_surface.name.to_s
							sub_surface_gross_area = sub_surface.grossArea.to_f
							window_wwr = sub_surface_gross_area/surface_grossArea
							uValue = sub_surface.uFactor.to_f
							uValue = construction_layers[0].to_SimpleGlazing.get.uFactor unless construction_layers[0] .to_SimpleGlazing.empty?
							uValue = construction_layers[0].to_StandardGlazing.get.thermalConductance unless construction_layers[0].to_StandardGlazing.empty?
							
							
							#calculating Ottv fenestration
							ottv_fenestration_conductance = 6 * window_wwr * uValue
							ottv_fenestration_shgc = 194 * subsurface_cf * window_wwr * sub_surface_sc
							window_solar_heat_gain_ottv_sum = window_solar_heat_gain_ottv_sum + ottv_fenestration_shgc							
							window_conduction_ottv_sum = window_conduction_ottv_sum + ottv_fenestration_conductance
							ottv_fenestration = ottv_fenestration + ottv_fenestration_conductance + ottv_fenestration_shgc
							
							
							if ( cnt > 1) #if more that one subsurface
								surface_ottv_summary << "<td></td><td></td><td></td><td></td></tr><tr><td></td><td></td><td></td><td></td><td></td><td></td>"
							end
							
							surface_ottv_summary << "<td> " << sub_surface_name << "</td>"
							surface_ottv_summary << "<td class='rightalign'> " << sub_surface_gross_area.round(2).to_s << "</td>"
							surface_ottv_summary << "<td class='rightalign'> " << window_wwr.round(2).to_s << "</td>"
							surface_ottv_summary << "<td class='rightalign'> " << uValue.round(2).to_s << "</td>"
							
							surface_ottv_summary << "<td  class='rightalign'>" << subsurface_cf.round(2).to_s << "</td>"
							surface_ottv_summary << "<td  class='rightalign'>" << sub_surface_sc.round(2).to_s << "</td>"
								
							surface_det = [sub_surface.name.to_s,sub_surface.subSurfaceType.to_s,sub_surface.space.get.name.to_s,sub_surface.construction.get.name.to_s,azimuth.round(1).to_s,facade]
							surface_details.push(surface_det)
								
							
						end # if window check ends
					end # sub surface loop ends
					
					if cnt == 0 	#if no subsurface
						surface_ottv_summary << "<td>  </td><td>  </td><td>  </td><td>  </td><td>  </td><td>  </td>"
																			
					end # if no subSurfaces end
					
					#calculating OTTV surface wise
					ottv = (ottv_wall + ottv_fenestration) # * multiplier
					surface_area_with_floor = surface_grossArea * multiplier
					surface_area_with_floor_sum = surface_area_with_floor_sum + surface_area_with_floor
					ottv_area_multi = ottv * surface_grossArea * multiplier
					ottv_area_multi_sum = ottv_area_multi_sum + ottv_area_multi
					surface_ottv_summary << "<td  style='text-align:right;'>" << ottv.round(2).to_s << "</td>"
					surface_ottv_summary << "<td  style='text-align:right;'> " << multiplier.to_s << "</td>"
					surface_ottv_summary << "<td  style='text-align:right;'> " << surface_area_with_floor.round(2).to_s << "</td>"						
					surface_ottv_summary << "<td  style='text-align:right;'>" << ottv_area_multi.round(2).to_s << "</td>"
					surface_ottv_summary << "</tr>"
					
						
				end   # if wind exposed wall ends
				if  surface.windExposure.to_s == "WindExposed" and surface.surfaceType == "RoofCeiling"
					surface_grossArea = surface.grossArea.to_f
					surface_uValue = surface.uFactor.to_f
					
					
				
				
				
				end  # if wind exposed roof ends
			end # surface loop ends
		end      # if conditioned ends
	end  #space loop end
	
	surface_ottv_summary << "<tr><th colspan='2' >Total </th>"
	surface_ottv_summary << "<th style='text-align:right;'>" << surface_area_sum.round(2).to_s << "</th>"
	surface_ottv_summary << "<td colspan='10'></td><td></td>"
	surface_ottv_summary << "<th  style='text-align:right;'>" << surface_area_with_floor_sum.round(2).to_s << "</th>"
	surface_ottv_summary << "<th  style='text-align:right;'>" << ottv_area_multi_sum.round(2).to_s << "</th></tr>"
	
	table_summary << "where,<br>"			
	table_summary << "<p style='padding-left:15px;'> &alpha; = Solar absorptivity of the opaque wall,<br>"	
	table_summary << "\t WWR = Window-to-gross exterior wall area ratio for the orientation under consideration,<br>"
	table_summary << "\t U<sub>w</sub> = Thermal transmittance of opaque wall (W/m<sup>2</sup>-&deg;K),<br>"
	table_summary << "\t U<sub>f</sub> = Thermal transmittance of fenestration system (W/m<sup>2</sup>-&deg;K),<br>"
	table_summary << "\t CF = Solar correction factor,<br>"
	table_summary << "\t SC = Shading coefficient of the fenestration system,<br>
	OTTV<sub>i</sub> = OTTV value for orientation i,<br>"
	table_summary << "\t FM = Floor Multiplier of zone<br>"
	
	
	
	table_summary << "</p>"
	
		###### chart start
	
	chart_str << "<div id='chartContainer_1'>"
     chart_str << "<script type='text/javascript'> "
     chart_str << " var svg = dimple.newSvg('#chartContainer_1', 500, 240); "
	 chart_str << "var data = [{'label':'Wall OTTV','value':" << wall_ottv_sum.round(2).to_s << ",'color':'#EF1C21'},{'label':'Window Conduction OTTV','value':" << window_conduction_ottv_sum.round(2).to_s << ",'color':'#0071BD'},{'label':'Window Solar Heat Gain OTTV','value':" << window_solar_heat_gain_ottv_sum.round(2).to_s << ",'color':'#F7DF10'}];"
     chart_str << " var myChart = new dimple.chart(svg, data);"
     chart_str << " myChart.setBounds(0, 20, 200, 200);
                        myChart.addMeasureAxis('p', 'value');
                        myChart.addSeries('label', dimple.plot.pie);
                        myChart.addLegend(225, 75, 175, 150, 'left');
                        
                        myChart.assignColor('Wall OTTV', '#EF1C21', 'white', 1);
                        
                        myChart.assignColor('Window Conduction OTTV', '#0071BD', 'white', 1);
                        
                        myChart.assignColor('Window Solar Heat Gain OTTV', '#F7DF10', 'white', 1);
                        
                      
                        
                        myChart.draw();
                    </script>
					<br>
					<p> <em>Chart showing component wise contribution towards OTTV</p></em>
                  </div><br><br>"
	
	########
	
	#calculating overall ottv		  
	ottv_result = ottv_area_multi_sum /surface_area_with_floor_sum
	if ottv_result <= 45.0
		table_summary << "<br> <h3><b>OTTV: </B> <font color='green'>" << ottv_result.round(2).to_s	<< " W/m<sup>2</sup></h3></font>"  
	else
		table_summary << "<br>  <h3><b>OTTV: </B><font color='red'>" << ottv_result.round(2).to_s	<< " W/m<sup>2</sup></h3></font>"  
	end
	
    table_summary << "<p>OTTV calculations as per MS 1525:2001 (Code of Practice on Energy Efficiency and Use of Renewable Energy for Non-Residential Buildings) for Malaysia. For compliance OTTV must not exceed 50 W/m<sup>2</sup> for buildings having total air-conditioned area of 4000m<sup>2</sup> or more.</p>"          
	table_summary << "<br><br>"
	
	proj_summary << "<td>" << ottv_result.round(2).to_s << "  W/m<sup>2</sup></td>"
	
	
	## Surface summary table
	surface_details.each do |surface_det|
		surface_summary << "<tr>"
		cnt = 0
		surface_det.each do |surface_data|
			if cnt == 4
				surface_summary << "<td class='rightalign'>" << surface_data << "</td>"
			else
				surface_summary << "<td>" << surface_data << "</td>"
			end	
			cnt = cnt + 1
		end
		surface_summary << "</tr>"
	end
	
	
	
	#### generation correction factor table #######
	cf.each do |key,value|
		cf_summary << "<tr>"
		cf_summary << "<td>" << key.to_s << "</td><td>" << value.to_s << "</td></tr>"
	end	
	



    web_asset_path = OpenStudio.getSharedResourcesPath() / OpenStudio::Path.new("web_assets")

    # read in template
    html_in_path = "#{File.dirname(__FILE__)}/resources/report.html.in"
    if File.exist?(html_in_path)
        html_in_path = html_in_path
    else
        html_in_path = "#{File.dirname(__FILE__)}/report.html.in"
    end
    html_in = ""
    File.open(html_in_path, 'r') do |file|
      html_in = file.read
    end

    # get the weather file run period (as opposed to design day run period)
    ann_env_pd = nil
    sqlFile.availableEnvPeriods.each do |env_pd|
      env_type = sqlFile.environmentType(env_pd)
      if env_type.is_initialized
        if env_type.get == OpenStudio::EnvironmentType.new("WeatherRunPeriod")
          ann_env_pd = env_pd
          break
        end
      end
    end

    # only try to get the annual timeseries if an annual simulation was run
    if ann_env_pd

      # get desired variable
      key_value =  "" # when used should be in all caps. In this case I'm using a meter vs. an output variable, and it doesn't have a key
      time_step = "Hourly" # "Zone Timestep", "Hourly", "HVAC System Timestep"
      variable_name = "Site Outdoor Air Drybulb Temperature"
      output_timeseries = sqlFile.timeSeries(ann_env_pd, time_step, variable_name, key_value) # key value would go at the end if we used it.
      
      if output_timeseries.empty?
        runner.registerWarning("Timeseries not found.")
      else
        runner.registerInfo("Found timeseries.")
      end
    else
      runner.registerWarning("No annual environment period found.")
    end
    
    # configure template with variable values
    renderer = ERB.new(html_in)
    html_out = renderer.result(binding)
    
    # write html file
    html_out_path = "./report.html"
    File.open(html_out_path, 'w') do |file|
      file << html_out
      # make sure data is written to the disk one way or the other
      begin
        file.fsync
      rescue
        file.flush
      end
    end

    # close the sql file
    sqlFile.close()

    return true
 
  end

end

# register the measure to be used by the application
OTTVWithRTTV.new.registerWithApplication
