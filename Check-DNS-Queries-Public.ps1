﻿param(
    [String] $filename=$null,
	[int] $Score_High_Threashold=30,
	[int] $Score_Medium_Threashold=18
	) 

<#
      Check-DNS-Queries.ps1

      \Input
      \Reports

 INPUTS:
   SIEM report of aggregated DNS data grouped together by count - formatted in date-time,src-ip,dst-domain
        - Processing can be done a couple of ways
           - If you can automate your SIEM DNS reports, run this on the hour and produce a csv file that is dropped in a holding area
           - If SIEM reports cannot be automated, manually run the report as often as you can, but try to run it once per day

   This file should be placed in the "Input" folder

 OUTPUTS:
  {currentdate}DGA.csv                 = list of potential DGA domains
  {currentdate}-Check-DNS-Queries.html = HTML Report of potential harmful domains
  {currentdate}-Like-Company.csv       = list of domains that have your company name in them but are not owned by you - could be phishing
  {currentdate}CheckDNSlog.csv         = A log of all filtered out domains
  
 REQUIREMENTS:
   A directory structure with "Input" and "Reports" directories.  This script should be placed at the root of those two directories

 TEXT FILES NEEDED FOR THIS TO RUN:
   domains_company.txt = company owned domains list (whitelisted).  Which domains does your company own?  These are considered good domains.
   domains_dyn.txt     = list of dynamic domains (can be retrieved from a website or built by hand)
   domains_hr.txt      = list of key words or domains that could point out potential HR violations
   domains_free.txt    = list of free domains (can be retrieved from a website or built by hand)
   domains_malware.txt = automatically downloaded list of malware domains.  Caution, this is downloaded, so anything added to it will be overwritten on the next script execution.
   domains_tld.txt     = automatically downloaded list of legitimate top level domains.  This is used to filter out illegitimate TLDs.
   domains_watch.txt   = watchlist of higher profile domains (put whatever in here that you want to flag)
   domains_apt.txt     = known APT domains
   domains_white.txt   = listing of domains that are okay.  Keep adding to this list of domains from your reports.  These could also be added as a filter at the SIEM level.
   ngrams.txt          = list of character sets used to determine if a domain is likely a DGA
#>
##############################################
#                                            #
# Get-Files                                  #
# - Download file from internet source       #
#                                            #
##############################################
Function Get-Files([string] $url, [string] $file)
{
	#$FilePath = $scriptPath+$file
	$FileExists = Test-Path $file
	If ($FileExists -eq $true)
	{
		$FileDate = (gci $file).LastWriteTime
		$FileDate = $FileDate.ToString("yyyyMMdd")
		if ($Date -ne $FileDate)
		{	
			$webclient = New-Object System.Net.WebClient
			$webclient.DownloadFile($url,$file)
		}
	}
	else
	{
		$webclient = New-Object System.Net.WebClient
		$webclient.DownloadFile($url,$file)	
	}
}
##############################################
#                                            #
# Get-RowColor                               #
# - alternate row colors on report           #
#                                            #
##############################################
Function Get-RowColor()
{
	#Set up Row Color
	if ($lc %2 -eq 0)
	{
		$HTMLContent = $HTMLContent + "`t`t`t<TR>`n"
	}
	else
	{
		$HTMLContent = $HTMLContent + "`t`t`t<TR class='alt'>`n"
	}
}
##############################################
#                                            #
# N-gram checking                            #
# - DGA identification                       #
#                                            #
##############################################
Function Get-BiTrigQuadgram([string] $Domain, [int] $GramLength)
{
	$Domain = $Domain.ToLower()
	#Get length of Domain
	$dom_length = $Domain.Length - $GramLength
	$i=0
	
	#This value is set to 1 so that the QuadgramValue can be multiplied by it initially
	#otherwise the QuadgramValue will always be 0
	$DomainValue = 1

	#only parse the word if the number of bi tri quad grams is at least equal to the length of the word
	#Meaning if we can at least get one "gram" out of the word, then process it
Function Get-BiTrigQuadgram([string] $Domain, [int] $GramLength)
{
	$Domain = $Domain.ToLower()
	#Get length of Domain
	$dom_length = $Domain.Length - $GramLength
	$i=0
	
	#This value is set to 1 so that the QuadgramValue can be multiplied by it initially
	#otherwise the QuadgramValue will always be 0
	$DomainValue = 1

	#only parse the word if the number of bi tri quad grams is at least equal to the length of the word
	#Meaning if we can at least get one "gram" out of the word, then process it
	if ($dom_length -le 0)  
	{
		#loop through the domain until all nGrams have been stored
		While ($i -le $dom_length)
		{

			#If the dictionary already contains the nGram then we want to increment the count as a match
			if ($global:BiTriQuadgramDict.ContainsKey($Domain.Substring($i,$GramLength)))
			{
				#Get the QuadGram
				$BiTriQuadgramValue = $global:BiTriQuadgramDict.Get_Item($Domain.Substring($i,$GramLength))
				#Calculate the domain score by multiplying it by the ngram percentage found in the hash table
				$DomainValue *= [double]$BiTriQuadgramValue
			}

			$i++
		}
	}

	return $DomainValue
}
##############################################
#                                            #
# See if a value is numeric                  #
#                                            #
##############################################
function isNumeric ($x) {
    try {
        0 + $x | Out-Null
        return $true
    } catch {
        return $false
    }
}

<#
          _____           _______                   _____                    _____                    _____          
         /\    \         /::\    \                 /\    \                  /\    \                  /\    \         
        /::\____\       /::::\    \               /::\    \                /::\    \                /::\    \        
       /:::/    /      /::::::\    \             /::::\    \               \:::\    \              /::::\    \       
      /:::/    /      /::::::::\    \           /::::::\    \               \:::\    \            /::::::\    \      
     /:::/    /      /:::/~~\:::\    \         /:::/\:::\    \               \:::\    \          /:::/\:::\    \     
    /:::/    /      /:::/    \:::\    \       /:::/  \:::\    \               \:::\    \        /:::/  \:::\    \    
   /:::/    /      /:::/    / \:::\    \     /:::/    \:::\    \              /::::\    \      /:::/    \:::\    \   
  /:::/    /      /:::/____/   \:::\____\   /:::/    / \:::\    \    ____    /::::::\    \    /:::/    / \:::\    \  
 /:::/    /      |:::|    |     |:::|    | /:::/    /   \:::\ ___\  /\   \  /:::/\:::\    \  /:::/    /   \:::\    \ 
/:::/____/       |:::|____|     |:::|    |/:::/____/  ___\:::|    |/::\   \/:::/  \:::\____\/:::/____/     \:::\____\
\:::\    \        \:::\    \   /:::/    / \:::\    \ /\  /:::|____|\:::\  /:::/    \::/    /\:::\    \      \::/    /
 \:::\    \        \:::\    \ /:::/    /   \:::\    /::\ \::/    /  \:::\/:::/    / \/____/  \:::\    \      \/____/ 
  \:::\    \        \:::\    /:::/    /     \:::\   \:::\ \/____/    \::::::/    /            \:::\    \             
   \:::\    \        \:::\__/:::/    /       \:::\   \:::\____\       \::::/____/              \:::\    \            
    \:::\    \        \::::::::/    /         \:::\  /:::/    /        \:::\    \               \:::\    \           
     \:::\    \        \::::::/    /           \:::\/:::/    /          \:::\    \               \:::\    \          
      \:::\    \        \::::/    /             \::::::/    /            \:::\    \               \:::\    \         
       \:::\____\        \::/____/               \::::/    /              \:::\____\               \:::\____\        
        \::/    /         ~~                      \::/____/                \::/    /                \::/    /        
         \/____/                                                            \/____/                  \/____/         
                                                                                                                    
#>
#create COM object
$wshell = New-Object -ComObject Wscript.Shell

#Check PowerShell Version
if ($PSVersionTable.PSVersion.Major -lt 3)
{
	$wshell.Popup("Invalid Powershell Version. This script requires version 3 or greater.",0,"Error", 0x0 + 0x30)
	Exit
}

#############################################
#                                           #
#                Variables                  #
#                                           #
#############################################
#Set script path
$scriptPath = "."
Set-Location -Path $scriptPath

#Get the input file and put into array
$domains = gc $filename

#set path of report
$reportPath = $scriptPath+"Reports\"

$CurrentDT = Get-Date -format yyyyMMddhhmm
$global:previousTime = 0
$global:SiteCounter = 0
$global:BiTriQuadGramDict = @{}
$global:MalwareDomainDict = @{}
$global:TLDDict = @{}
$global:DynDomainsDict = @{}
$DGA_Count = $null
$DGA2_Count = $null

#############################################
#                                           #
#            Get files from internet        #
#                                           #
#############################################
Get-Files "http://www.malwaredomainlist.com/hostslist/hosts.txt" $scriptPath"domains_malware.txt"
Get-Files "http://data.iana.org/TLD/tlds-alpha-by-domain.txt" $scriptPath"domains_tld.txt"

#############################################
#                                           #
#   Set up various lists of domains         #
#                                           #
#############################################
#Get Whitelisted Domains
$whiteDomains = gc $scriptPath"domains_white.txt"

#create dictionary of the domains_company.txt file
$companyDomains = gc $scriptPath"domains_company.txt"

#Download malware domains lists
$Date = Get-Date
$Date = $Date.ToString("yyyyMMdd")

$malDomains = gc $scriptPath"domains_malware.txt"
$malDomains = $malDomains -replace "127.0.0.1  ",""

#Get TLDs
$tldDomains = gc $scriptPath"domains_tld.txt"

#Get dyndns list
$dynDomains = gc $scriptPath"domains_dyn.txt"

#Get free domains list
$freeDomains = gc $scriptPath"domains_free.txt"

#Domains to watch
$watchDomains = gc $scriptPath"domains_watch.txt"

#Threat Intelligence domains list
$TIDomains = gc $scriptPath"domains_ti.txt"

#HR Violation domains list
$global:hrDomains = gc $scriptPath"domains_hr.txt"

#Put the ngrams into a dictionary for searching
$SiteList = gc "ngrams.txt"
foreach ($site in $SiteList)
{
	$split = $site.Split(",")
	$bitriquadgram = $split[0]
	$reliability  = $split[1]
	$global:BiTriQuadgramDict.Set_Item($bitriquadgram,$reliability)
}

#############################################
#                                           #
#       Create csv output files             #
#                                           #
#############################################
Add-Content $reportPath$CurrentDT"-DGA.csv" "Domain,IP,DateTime,Hits,Score,Length1,DomainPart1,Length2"
Add-Content $reportPath$CurrentDT"-DGA2.csv" "Domain,IP,DateTime,Hits,Score,Length1,DomainPart1,Length2,DomainPart2,Length3,DomainPart3,Length4"

#############################################
#                                           #
#      Create HTML Report variable          #
#                                           #
#############################################
$HTMLFile = $reportPath+$CurrentDT+"-Check-DNS-Queries.html"
$HTMLContent = ""

$HTMLContent = $HTMLContent + "<HTML><BODY><HEAD><STYLE>#DNS{font-family:`"Trebuchet MS`", Arial, Helvetica, sans-serif;width:100%;border-collapse:collapse;}" +
					  "#Legend{" +
					  "`t`t`t`t`tfont-family:`"Trebuchet MS`", Arial, Helvetica, sans-serif;`n" +
					  "`t`t`t`t`twidth:40%;`n" +
					  "`t`t`t`t`tborder-collapse:collapse;`n`t`t`t`t}`n" +
					  "`t`t`t`t#VPN td, #DNS th, #Legend td, #Legend th`n" +
					  "`t`t`t`t{`n`t`t`t`t`tfont-size:1em;`n" +
					  "`t`t`t`t`tborder:1px solid #98bf21;`n" +
					  "`t`t`t`t`tpadding:3px 7px 2px 7px;`n" +
					  "`t`t`t`t}`n`t`t`t`t#DNS th`n`t`t`t`t{`n" +
					  "`t`t`t`t`tfont-size:1.1em;`n`t`t`t`t`ttext-align:left;`n" +
					  "`t`t`t`t`tpadding-top:5px;`n`t`t`t`t`tpadding-bottom:4px;`n" +
					  "`t`t`t`t`tbackground-color:#A7C942;`n`t`t`t`t`tcolor:#ffffff;`n" +
					  "`t`t`t`t`}`n`t`t`t`t#Legend th`n`t`t`t`t{`n`t`t`t`t`tfont-size:1.1em;`n" +
					  "`t`t`t`t`ttext-align:left;`n`t`t`t`t`tpadding-top:5px;`n" +
					  "`t`t`t`t`tpadding-bottom:4px;`n`t`t`t`t`tbackground-color:#0404B4;`n" +
					  "`t`t`t`t`tcolor:#ffffff;`n`t`t`t`t}`n`t`t`t`t#DNS tr.alt td`n" +
					  "`t`t`t`t{`n`t`t`t`t`tcolor:#000000;`n`t`t`t`t`tbackground-color:#EAF2D3;`n" +
					  "`t`t`t`t}`n`t`t`t</style>`n`t`t</head>`n`t`t<TABLE ID=`"DNS`">`n`t`t`t<TR>`n" +
				      "`t`t`t`t<TH>Date-Time</TH><TH>Host</TH><TH>Domain</TH><TH>Alert</TH>`n" +
					  "`t`t`t</TR>`n" 
$lc=0

foreach ($line in $domains)
{
	$lc++ #line count

	$line = $line.ToLower()
	if ($line -eq "")
	{
		#do nothing if line in csv is blank
	}
	else
	{
		#$dom = $null
		$parts = $line.Split(',')
		$domain_name = $parts[0]
		#split out the domain
		$dom = $parts[0].split('.')
		#count the number of parts to the domain
		$dom_count = $dom.count
		#Just want the root domain and suffix
		$root_dom = $dom[-2]+"."+$dom[-1]
		$TLD_dom = $dom[-1]
		$SLD_dom = $dom[-2]
		#count the digits in the DNS name
		$digits_dom = [regex]::matches($parts[0],"[0-9]").count
		#count the dashes in the root domain name (minus the suffix) - used for phishing
		$dash_count = [regex]::matches($dom[-2],"-").count
		#How many parts to the domain are there?
		$domainElement_count = $parts[0].Split(".").Length
        $Host_IP = $parts[1]
        $DateTime = $parts[2]+","+$parts[3]+","+$parts[4]
        $Hits = $parts[5]
		
		#######################
		#
		#       Filter
		#
		#######################
		
 		if ($tldDomains -NotContains $TLD_dom)
		#if it is a non-existent TLD then put it into the log
		{
			Add-Content -Path $reportPath$CurrentDT"CheckDNSlog.csv" $line",Non-existent TLD"
		}
		#check whitelist
		elseif ($whiteDomains.Contains($root_dom) -or $whiteDomains.Contains($SLD_dom) -or $whiteDomains.Contains($parts[0]))
		{
			#do nothing
		}
		#derivations of company owned domains
		elseif ($companyDomains.contains($root_dom))
		{
			#do nothing
		}
		#Filter out workstations, servers, and printers at this point, so what's left will
		#be unresolvable which could include DGA's

		elseif (($domain_name.Contains(".arpa")) -or ($domain_name.Contains(".mig")) -or `
		        ($domain_name.Contains("_tcp")) -or `
				($domain_name.Contains("_sip")) -or ($domain_name.Contains("_udp")) -or `
				($domain_name -match ".local$") -or `
				($domain_name -match ".localhost$") -or ($domain_name -match ".localdomain$"))
		{
			#do nothing
		}
		#eliminate cdn servers
		elseif (($domain_name -match "cdn([0-9]{1,2})") -or ($domain_name -match "cdn-([0-9]{1,2})"))
		{
			#do nothing
		}
		#######################
		#
		#       Identify
		#
		#######################
		#Threat Intelligence Domains
		elseif ($TIDomains.Contains($domain_name))
		{
			Write-Host $domain_name " - ELEVATED Threat Intelligence DOMAIN, IP = "$Host_IP -ForegroundColor Red -BackgroundColor Black
			Get-RowColor
			$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='red'><B>"+$domain_name+"</B></font></TD><TD>Threat Intelligence Domain</TD></TR>`n"
		}
		#Watched Domains
		elseif ($watchDomains.Contains($domain_name))
		{
			Write-Host $domain_name " - ELEVATED WATCHED DOMAIN, IP = "$Host_IP -ForegroundColor Red -BackgroundColor Black
			Get-RowColor
			$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='red'><B>"+$domain_name+"</B></font></TD><TD>Watch Domain</TD></TR>`n"
		}
		#HR Policy Violations
		elseif ($hrDomains.Contains($root_dom))
		{
			Write-Host $domain_name " - HR VIOLATION, IP = "$Host_IP -ForegroundColor Red -BackgroundColor Black
			Get-RowColor
			$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='orange'><B>"+$domain_name+"</B></font></TD><TD>HR Violation</TD></TR>`n"
		}
		#Malware Domains
		elseif ($malDomains.contains($domain_name))
		{
			Write-Host $domain_name " - ELEVATED Malware Domain, IP = "$Host_IP -ForegroundColor Red -BackgroundColor Black
			Get-RowColor
			$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='red'><B>"+$domain_name+"</B></font></TD><TD>Malware</TD></TR>`n"
		}
		#Dynamic Domains
		elseif ($dynDomains.contains($root_dom))
		{
			Write-Host $domain_name " - DynDNS Domain, IP = "$Host_IP -ForegroundColor Magenta
			Get-RowColor
			$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='Magenta'><B>"+$domain_name+"</B></font></TD><TD>Dynamic DNS</TD></TR>`n"
		}
		#Free Domains
		elseif ($freeDomains.contains($root_dom))
		{
			Write-Host $domain_name " - Free Hosted Domain, IP = "$Host_IP -ForegroundColor DarkGreen
			Get-RowColor
			$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='green'><B>"+$domain_name+"</B></font></TD><TD>Free Domain</TD></TR>`n"
		}
		elseif (($domain_name.contains("yourcomapanyname")) -and ($root_dom -ne "yourcompany.com"))
		{
			#This puts all domains with your company domain in it into a separate file for review
			#Sometimes threat actors will create domains that blend in with your company name
			Add-Content -Path $reportPath$CurrentDT"-Like-Company.csv" $line","$parts_len","$TLD_dom","$SLD_dom","$SLD_len
		}
		########################
		  #                  #
		  ##                ##
		  ###  DGA  Logic  ###
		  ##	            ##
		  #                  #
		########################
		else
		{
			#DGA's typically do not have www in them
			if ($domain_name -notmatch "www")
			{
				$Possible_DGA_domain = $domain_name.Split(".")
				$Possible_DGA = $false
				$Domain_string = ""
				$parts_len = $domain_name.Length
				
				$Score = 0
				
				foreach ($subdomain in $Possible_DGA_domain)
				{
					
					#We aren't interested in subdomains with all integers, any dashes
					if ((isNumeric $subdomain) -or $subdomain.contains("-"))
					{
						#Do Nothing
					}
					else
					{
						#Since each domain has a different length we want to be sure to treat it equally, so
						#calculate the score based on the domain length and the bigram score it receives.

						$BiScore = $subdomain.Length * (Get-BiTrigQuadgram $subdomain 2)
						$TriScore = $subdomain.Length * (Get-BiTrigQuadgram $subdomain 3)
						$QuadScore = $subdomain.Length * (Get-BiTrigQuadgram $subdomain 4)
												
						#Add the scores together for all subdomains
						$Score = $Score + ($BiScore + $TriScore + $QuadScore)
						
						$Domain_string += "$subdomain,"+$subdomain.Length+","
					}
					
				}
				#The Score_Threshold is the tolerance level.  Increase this value if you want to find DGA's easier
				#If you increase the value, you may potentially filter out DGA's with a lower score
				#If you decrease this value, your report will be large, but you will potentially catch all of the
				#DGA's.
				if ($Score -ge $Score_High_Threashold)
				{
					Add-Content $reportPath$CurrentDT"-DGA.csv" $line","$Score","$parts_len","$Domain_string
					Get-RowColor
					$HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='red'>"+$domain_name+"</font></TD><TD>DGA High</TD></TR>`n"
				}
				elseif ($Score -ge $Score_Medium_Threashold)
				{
					Add-Content $reportPath$CurrentDT"-DGA2.csv" $line","$Score","$parts_len","$Domain_string
					Get-RowColor
                    $HTMLContent = $HTMLContent + "`t`t`t`t<TR><TD>"+$DateTime+"</TD><TD>"+$Host_IP+"</TD><TD><font color='orange'>"+$domain_name+"</font></TD><TD>DGA Medium</TD></TR>`n"
				}
			}
			else
			{
				#This is in case you would like to log any domains that fall through the logic
				#Add-Content $reportPath$CurrentDT"-Extra.csv" $line","$parts_len","$TLD_dom","$SLD_dom","$SLD_len
			}
		}
	}
}

$HTMLContent = $HTMLContent + "`t`t</TABLE>`n`t</BODY>`n</HTML>`n"
					  
Add-Content $HTMLFile $HTMLContent

Import-CSV $reportPath$CurrentDT"-DGA.csv" | Sort-Object {[int] $_.Score} -descending | Export-Csv $reportPath$CurrentDT"-DGA-S.csv" -NoTypeInformation
Import-CSV $reportPath$CurrentDT"-DGA2.csv" | Sort-Object {[int] $_.Score} -descending | Export-Csv $reportPath$CurrentDT"-DGA2-S.csv" -NoTypeInformation

$DGA_Count = Import-Csv $reportPath$CurrentDT"-DGA-S.csv" | Measure-Object
$DGA2_Count = Import-Csv $reportPath$CurrentDT"-DGA2-S.csv" | Measure-Object

#We actually want content if we send an email, so count the number of records in the csv files and see if it's worth sending the email
if (($DGA_Count.Count -gt 0) -or ($DGA2_Count.Count -gt 0))
{
	Send-MailMessage -To "to@mail.com" -From "from@mail.com" -Subject "Domain Report" -Body "$HTMLContent" -SmtpServer smtp.company.com -BodyAsHtml
}
