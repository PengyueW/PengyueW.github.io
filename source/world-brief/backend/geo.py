"""Gazetteer-based location extraction: countries, capitals, major cities, regions."""
import hashlib
import re
import unicodedata
from collections import Counter

from .countries import COUNTRIES, COUNTRY_BY_CODE, CASE_SENSITIVE_ALIASES

# Major cities and hotspots with their own coordinates: name -> (lat, lon, country)
CITIES = {
 "New York": (40.71,-74.01,"US"), "Los Angeles": (34.05,-118.24,"US"), "Chicago": (41.88,-87.63,"US"), "Washington": (38.91,-77.04,"US"),
 "San Francisco": (37.77,-122.42,"US"), "Silicon Valley": (37.39,-122.08,"US"), "Wall Street": (40.71,-74.01,"US"), "Miami": (25.76,-80.19,"US"),
 "Houston": (29.76,-95.37,"US"), "Texas": (31.0,-100.0,"US"), "California": (36.78,-119.42,"US"), "Florida": (27.66,-81.52,"US"),
 "London": (51.51,-0.13,"GB"), "Manchester": (53.48,-2.24,"GB"), "Edinburgh": (55.95,-3.19,"GB"), "Belfast": (54.6,-5.93,"GB"),
 "Paris": (48.86,2.35,"FR"), "Marseille": (43.3,5.37,"FR"), "Berlin": (52.52,13.4,"DE"), "Munich": (48.14,11.58,"DE"), "Frankfurt": (50.11,8.68,"DE"),
 "Rome": (41.9,12.5,"IT"), "Milan": (45.46,9.19,"IT"), "Madrid": (40.42,-3.7,"ES"), "Barcelona": (41.39,2.17,"ES"),
 "Brussels": (50.85,4.35,"BE"), "Amsterdam": (52.37,4.9,"NL"), "The Hague": (52.08,4.31,"NL"), "Geneva": (46.2,6.14,"CH"), "Zurich": (47.38,8.54,"CH"), "Davos": (46.8,9.84,"CH"),
 "Vienna": (48.21,16.37,"AT"), "Warsaw": (52.23,21.01,"PL"), "Prague": (50.08,14.44,"CZ"), "Budapest": (47.5,19.04,"HU"), "Athens": (37.98,23.73,"GR"),
 "Stockholm": (59.33,18.07,"SE"), "Oslo": (59.91,10.75,"NO"), "Copenhagen": (55.68,12.57,"DK"), "Helsinki": (60.17,24.94,"FI"), "Dublin": (53.35,-6.26,"IE"),
 "Lisbon": (38.72,-9.14,"PT"), "Bucharest": (44.43,26.1,"RO"), "Belgrade": (44.79,20.47,"RS"), "Sarajevo": (43.86,18.41,"BA"), "Kosovo": (42.6,20.9,"XK"),
 "Moscow": (55.76,37.62,"RU"), "Kremlin": (55.75,37.62,"RU"), "St Petersburg": (59.93,30.32,"RU"), "Saint Petersburg": (59.93,30.32,"RU"), "Vladivostok": (43.12,131.89,"RU"), "Belgorod": (50.6,36.59,"RU"), "Kursk": (51.73,36.19,"RU"),
 "Kyiv": (50.45,30.52,"UA"), "Kiev": (50.45,30.52,"UA"), "Kharkiv": (49.99,36.23,"UA"), "Odesa": (46.48,30.73,"UA"), "Odessa": (46.48,30.73,"UA"), "Donetsk": (48.0,37.8,"UA"),
 "Luhansk": (48.57,39.31,"UA"), "Zaporizhzhia": (47.84,35.14,"UA"), "Kherson": (46.64,32.62,"UA"), "Crimea": (45.0,34.1,"UA"), "Sevastopol": (44.62,33.53,"UA"), "Pokrovsk": (48.28,37.18,"UA"), "Sumy": (50.9,34.8,"UA"), "Dnipro": (48.47,35.04,"UA"),
 "Minsk": (53.9,27.57,"BY"), "Chisinau": (47.01,28.86,"MD"), "Transnistria": (47.0,29.5,"MD"), "Tbilisi": (41.72,44.83,"GE"), "Yerevan": (40.18,44.51,"AM"), "Baku": (40.41,49.87,"AZ"), "Nagorno-Karabakh": (39.8,46.75,"AZ"),
 "Istanbul": (41.01,28.98,"TR"), "Ankara": (39.93,32.87,"TR"), "Izmir": (38.42,27.13,"TR"),
 "Jerusalem": (31.77,35.22,"IL"), "Tel Aviv": (32.08,34.78,"IL"), "Haifa": (32.79,34.99,"IL"), "Gaza": (31.5,34.47,"PS"), "Gaza City": (31.5,34.47,"PS"), "Rafah": (31.29,34.25,"PS"), "Khan Younis": (31.34,34.31,"PS"),
 "West Bank": (32.0,35.3,"PS"), "Ramallah": (31.9,35.2,"PS"), "Jenin": (32.46,35.3,"PS"), "Nablus": (32.22,35.26,"PS"), "Hebron": (31.53,35.1,"PS"),
 "Beirut": (33.89,35.5,"LB"), "Damascus": (33.51,36.29,"SY"), "Aleppo": (36.2,37.16,"SY"), "Idlib": (35.93,36.63,"SY"), "Latakia": (35.52,35.79,"SY"), "Homs": (34.73,36.72,"SY"),
 "Baghdad": (33.32,44.37,"IQ"), "Erbil": (36.19,44.01,"IQ"), "Mosul": (36.34,43.13,"IQ"), "Basra": (30.51,47.81,"IQ"), "Kirkuk": (35.47,44.39,"IQ"),
 "Tehran": (35.69,51.39,"IR"), "Isfahan": (32.65,51.68,"IR"), "Natanz": (33.51,51.92,"IR"), "Strait of Hormuz": (26.57,56.25,"IR"),
 "Riyadh": (24.71,46.68,"SA"), "Jeddah": (21.49,39.19,"SA"), "Mecca": (21.39,39.86,"SA"), "Dubai": (25.2,55.27,"AE"), "Abu Dhabi": (24.45,54.38,"AE"), "Doha": (25.29,51.53,"QA"),
 "Sanaa": (15.37,44.19,"YE"), "Aden": (12.79,45.03,"YE"), "Hodeidah": (14.8,42.95,"YE"), "Red Sea": (20.0,38.5,"YE"), "Bab el-Mandeb": (12.58,43.33,"YE"),
 "Cairo": (30.04,31.24,"EG"), "Sinai": (29.5,33.8,"EG"), "Suez Canal": (30.46,32.35,"EG"), "Alexandria": (31.2,29.92,"EG"),
 "Tripoli": (32.89,13.19,"LY"), "Benghazi": (32.12,20.07,"LY"), "Tunis": (36.81,10.18,"TN"), "Algiers": (36.75,3.06,"DZ"), "Casablanca": (33.57,-7.59,"MA"), "Rabat": (34.02,-6.84,"MA"), "Western Sahara": (24.5,-13.0,"MA"),
 "Khartoum": (15.5,32.56,"SD"), "Darfur": (13.5,25.0,"SD"), "El Fasher": (13.63,25.35,"SD"), "Port Sudan": (19.62,37.22,"SD"), "Juba": (4.86,31.57,"SS"),
 "Addis Ababa": (9.02,38.75,"ET"), "Tigray": (14.0,38.5,"ET"), "Amhara": (11.5,38.0,"ET"), "Mogadishu": (2.05,45.32,"SO"), "Somaliland": (9.56,44.07,"SO"), "Nairobi": (-1.29,36.82,"KE"), "Mombasa": (-4.04,39.67,"KE"),
 "Kampala": (0.35,32.58,"UG"), "Dar es Salaam": (-6.79,39.28,"TZ"), "Kigali": (-1.94,30.06,"RW"), "Kinshasa": (-4.44,15.27,"CD"), "Goma": (-1.68,29.22,"CD"), "Bukavu": (-2.5,28.86,"CD"), "Kivu": (-1.5,28.9,"CD"),
 "Lagos": (6.52,3.38,"NG"), "Abuja": (9.06,7.49,"NG"), "Kano": (12.0,8.52,"NG"), "Borno": (11.85,13.15,"NG"), "Accra": (5.6,-0.19,"GH"), "Dakar": (14.69,-17.44,"SN"), "Abidjan": (5.36,-4.01,"CI"),
 "Bamako": (12.64,-8.0,"ML"), "Ouagadougou": (12.37,-1.52,"BF"), "Niamey": (13.51,2.11,"NE"), "N'Djamena": (12.13,15.06,"TD"), "Sahel": (14.5,0.0,"ML"),
 "Johannesburg": (-26.2,28.05,"ZA"), "Cape Town": (-33.92,18.42,"ZA"), "Durban": (-29.86,31.02,"ZA"), "Pretoria": (-25.75,28.19,"ZA"), "Harare": (-17.83,31.05,"ZW"), "Lusaka": (-15.39,28.32,"ZM"), "Maputo": (-25.97,32.57,"MZ"), "Cabo Delgado": (-12.3,39.5,"MZ"), "Luanda": (-8.84,13.23,"AO"),
 "Beijing": (39.9,116.41,"CN"), "Shanghai": (31.23,121.47,"CN"), "Shenzhen": (22.54,114.06,"CN"), "Guangzhou": (23.13,113.26,"CN"), "Xinjiang": (41.0,85.0,"CN"), "Tibet": (31.5,88.0,"CN"), "Hong Kong": (22.32,114.17,"HK"), "Macau": (22.2,113.54,"MO"), "Wuhan": (30.59,114.31,"CN"), "Chengdu": (30.57,104.07,"CN"),
 "Taipei": (25.03,121.57,"TW"), "Kaohsiung": (22.63,120.3,"TW"), "Taiwan Strait": (24.0,119.5,"TW"), "South China Sea": (12.0,114.0,"PH"), "Scarborough Shoal": (15.15,117.77,"PH"), "Second Thomas Shoal": (9.73,115.87,"PH"),
 "Tokyo": (35.68,139.69,"JP"), "Osaka": (34.69,135.5,"JP"), "Okinawa": (26.33,127.8,"JP"), "Fukushima": (37.75,140.47,"JP"), "Hiroshima": (34.39,132.46,"JP"), "Seoul": (37.57,126.98,"KR"), "Busan": (35.18,129.08,"KR"), "Pyongyang": (39.02,125.75,"KP"), "DMZ": (38.0,127.0,"KP"),
 "New Delhi": (28.61,77.21,"IN"), "Delhi": (28.61,77.21,"IN"), "Mumbai": (19.08,72.88,"IN"), "Bengaluru": (12.97,77.59,"IN"), "Bangalore": (12.97,77.59,"IN"), "Chennai": (13.08,80.27,"IN"), "Kolkata": (22.57,88.36,"IN"), "Hyderabad": (17.39,78.49,"IN"), "Kashmir": (34.08,74.8,"IN"), "Manipur": (24.8,93.95,"IN"),
 "Islamabad": (33.68,73.05,"PK"), "Karachi": (24.86,67.01,"PK"), "Lahore": (31.55,74.34,"PK"), "Balochistan": (28.5,65.5,"PK"), "Peshawar": (34.01,71.58,"PK"), "Kabul": (34.53,69.17,"AF"), "Kandahar": (31.63,65.71,"AF"),
 "Dhaka": (23.81,90.41,"BD"), "Cox's Bazar": (21.43,92.0,"BD"), "Colombo": (6.93,79.85,"LK"), "Kathmandu": (27.72,85.32,"NP"), "Everest": (27.99,86.93,"NP"),
 "Bangkok": (13.76,100.5,"TH"), "Hanoi": (21.03,105.85,"VN"), "Ho Chi Minh City": (10.82,106.63,"VN"), "Manila": (14.6,120.98,"PH"), "Mindanao": (8.0,125.0,"PH"), "Jakarta": (-6.21,106.85,"ID"), "Bali": (-8.34,115.09,"ID"), "Sumatra": (-0.6,101.3,"ID"), "Papua": (-4.3,138.0,"ID"),
 "Kuala Lumpur": (3.14,101.69,"MY"), "Singapore": (1.29,103.85,"SG"), "Yangon": (16.87,96.2,"MM"), "Rakhine": (20.1,93.6,"MM"), "Phnom Penh": (11.56,104.92,"KH"), "Vientiane": (17.97,102.63,"LA"),
 "Astana": (51.17,71.45,"KZ"), "Almaty": (43.24,76.93,"KZ"), "Tashkent": (41.3,69.24,"UZ"), "Bishkek": (42.87,74.59,"KG"), "Dushanbe": (38.56,68.77,"TJ"), "Ulaanbaatar": (47.89,106.91,"MN"),
 "Sydney": (-33.87,151.21,"AU"), "Melbourne": (-37.81,144.96,"AU"), "Brisbane": (-27.47,153.03,"AU"), "Perth": (-31.95,115.86,"AU"), "Canberra": (-35.28,149.13,"AU"), "Auckland": (-36.85,174.76,"NZ"), "Wellington": (-41.29,174.78,"NZ"), "Christchurch": (-43.53,172.64,"NZ"),
 "Port Moresby": (-9.44,147.18,"PG"), "Bougainville": (-6.0,155.0,"PG"), "Honiara": (-9.43,159.95,"SB"), "Suva": (-18.14,178.44,"FJ"), "Nouméa": (-22.28,166.46,"FR"), "New Caledonia": (-21.3,165.5,"FR"), "Tahiti": (-17.65,-149.43,"FR"),
 "Ottawa": (45.42,-75.7,"CA"), "Toronto": (43.65,-79.38,"CA"), "Vancouver": (49.28,-123.12,"CA"), "Montreal": (45.5,-73.57,"CA"), "Quebec": (46.81,-71.21,"CA"), "Alberta": (53.93,-116.58,"CA"),
 "Mexico City": (19.43,-99.13,"MX"), "Tijuana": (32.51,-117.04,"MX"), "Sinaloa": (25.0,-107.5,"MX"), "Ciudad Juárez": (31.69,-106.42,"MX"), "Guadalajara": (20.66,-103.35,"MX"), "Monterrey": (25.69,-100.32,"MX"),
 "Havana": (23.11,-82.37,"CU"), "Guantánamo": (20.0,-75.1,"CU"), "Port-au-Prince": (18.54,-72.34,"HT"), "Santo Domingo": (18.49,-69.93,"DO"), "Kingston": (17.97,-76.79,"JM"), "Panama Canal": (9.08,-79.68,"PA"),
 "Bogotá": (4.71,-74.07,"CO"), "Bogota": (4.71,-74.07,"CO"), "Medellín": (6.25,-75.56,"CO"), "Caracas": (10.49,-66.88,"VE"), "Essequibo": (6.0,-59.0,"GY"), "Quito": (-0.18,-78.47,"EC"), "Guayaquil": (-2.17,-79.92,"EC"), "Lima": (-12.05,-77.04,"PE"),
 "La Paz": (-16.5,-68.15,"BO"), "Santiago": (-33.45,-70.67,"CL"), "Buenos Aires": (-34.6,-58.38,"AR"), "Montevideo": (-34.9,-56.16,"UY"), "Asunción": (-25.26,-57.58,"PY"),
 "Brasília": (-15.79,-47.88,"BR"), "Brasilia": (-15.79,-47.88,"BR"), "São Paulo": (-23.55,-46.63,"BR"), "Sao Paulo": (-23.55,-46.63,"BR"), "Rio de Janeiro": (-22.91,-43.17,"BR"), "Amazon rainforest": (-3.0,-60.0,"BR"),

 # Sub-national places whose name collides with a country's; the longer span wins in the scan.
 "Niger State": (10.0,6.0,"NG"), "Niger Delta": (5.3,6.5,"NG"), "Georgia State": (32.17,-82.9,"US"),
 "State of Georgia": (32.17,-82.9,"US"), "Mexico City": (19.43,-99.13,"MX"), "New Mexico": (34.5,-105.9,"US"),
 "Jordan River": (32.0,35.55,"IL"), "Chad Lake": (13.0,14.2,"TD"), "Lake Chad": (13.0,14.2,"TD"),
 "Antarctica": (-82.0,0.0,None), "Arctic": (80.0,0.0,None), "Greenland": (72.0,-40.0,"DK"), "Svalbard": (78.0,16.0,"NO"), "Black Sea": (43.5,34.0,"UA"), "Baltic Sea": (58.0,20.0,"SE"), "Persian Gulf": (26.5,52.0,"IR"), "Mediterranean": (35.0,18.0,"IT"),
}

# Foreign-language spellings of the places that drive world news. Sharing a *specific* place
# (not merely a country) is what lets the same story merge across languages.
CITY_ALIASES = {
 "Groenlandia": "Greenland", "Groenland": "Greenland", "Grönland": "Greenland", "Groenlândia": "Greenland", "Grønland": "Greenland",
 "Gaza": "Gaza", "Gazze": "Gaza", "Газа": "Gaza", "غزة": "Gaza", "加沙": "Gaza",
 "Jerusalén": "Jerusalem", "Jérusalem": "Jerusalem", "Gerusalemme": "Jerusalem", "Jerusalém": "Jerusalem", "Kudüs": "Jerusalem", "القدس": "Jerusalem",
 "Cisjordania": "West Bank", "Cisjordanie": "West Bank", "Westjordanland": "West Bank", "Cisgiordania": "West Bank", "Cisjordânia": "West Bank",
 "Kiev": "Kyiv", "Kiew": "Kyiv", "Kijów": "Kyiv", "Киев": "Kyiv", "Київ": "Kyiv", "基辅": "Kyiv",
 "Moscú": "Moscow", "Moscou": "Moscow", "Moskau": "Moscow", "Mosca": "Moscow", "Moscovo": "Moscow", "Москва": "Moscow", "莫斯科": "Moscow", "Moskova": "Moscow",
 "Pekín": "Beijing", "Pékin": "Beijing", "Peking": "Beijing", "Pechino": "Beijing", "Pequim": "Beijing", "北京": "Beijing", "Пекин": "Beijing",
 "Kremlin": "Kremlin", "Cremlino": "Kremlin", "Кремль": "Kremlin", "Kreml": "Kremlin",
 "Casa Blanca": "White House", "Maison Blanche": "White House", "Weißes Haus": "White House", "Casa Bianca": "White House", "Casa Branca": "White House", "Белый дом": "White House", "白宫": "White House", "Beyaz Saray": "White House", "البيت الأبيض": "White House",
 "Crimea": "Crimea", "Crimée": "Crimea", "Krim": "Crimea", "Krym": "Crimea", "Крым": "Crimea",
 "Donbás": "Donetsk", "Donbass": "Donetsk", "Donbas": "Donetsk", "Донбасс": "Donetsk", "Donezk": "Donetsk",
 "Járkov": "Kharkiv", "Kharkov": "Kharkiv", "Charkiw": "Kharkiv", "Харьков": "Kharkiv",
 "Odesa": "Odesa", "Odessa": "Odesa", "Одесса": "Odesa",
 "Mar Rojo": "Red Sea", "mer Rouge": "Red Sea", "Rotes Meer": "Red Sea", "Mar Rosso": "Red Sea", "Mar Vermelho": "Red Sea", "البحر الأحمر": "Red Sea", "红海": "Red Sea",
 "Estrecho de Ormuz": "Strait of Hormuz", "détroit d'Ormuz": "Strait of Hormuz", "Straße von Hormus": "Strait of Hormuz", "stretto di Hormuz": "Strait of Hormuz", "Ormuz": "Strait of Hormuz", "Hormuz": "Strait of Hormuz",
 "Canal de Suez": "Suez Canal", "canal de Suez": "Suez Canal", "Sueskanal": "Suez Canal", "canale di Suez": "Suez Canal", "Canal do Suez": "Suez Canal",
 "Canal de Panamá": "Panama Canal", "canal de Panama": "Panama Canal", "Panamakanal": "Panama Canal", "canale di Panama": "Panama Canal",
 "Estrecho de Taiwán": "Taiwan Strait", "détroit de Taïwan": "Taiwan Strait", "Taiwanstraße": "Taiwan Strait", "stretto di Taiwan": "Taiwan Strait", "台湾海峡": "Taiwan Strait",
 "Mar de China Meridional": "South China Sea", "mer de Chine méridionale": "South China Sea", "Südchinesisches Meer": "South China Sea", "Mar Cinese Meridionale": "South China Sea", "南海": "South China Sea",
 "Darfur": "Darfur", "Darfour": "Darfur", "دارفور": "Darfur",
 "Sahel": "Sahel", "Sahelzone": "Sahel", "الساحل": "Sahel",
 "Cachemira": "Kashmir", "Cachemire": "Kashmir", "Kaschmir": "Kashmir", "Kashmir": "Kashmir", "克什米尔": "Kashmir",
 "Amazonía": "Amazon rainforest", "Amazonie": "Amazon rainforest", "Amazonas": "Amazon rainforest", "Amazzonia": "Amazon rainforest", "Amazônia": "Amazon rainforest",
 "Tíbet": "Tibet", "Tibet": "Tibet", "西藏": "Tibet", "Xinjiang": "Xinjiang", "新疆": "Xinjiang", "Sinkiang": "Xinjiang",
 "Hong Kong": "Hong Kong", "Hongkong": "Hong Kong", "香港": "Hong Kong",
 "Nueva York": "New York", "New York": "New York", "Nova York": "New York", "纽约": "New York", "Нью-Йорк": "New York",
 "Washington": "Washington", "Вашингтон": "Washington", "华盛顿": "Washington",
 "Bruselas": "Brussels", "Bruxelles": "Brussels", "Brüssel": "Brussels", "Bruxelas": "Brussels",
 "Ginebra": "Geneva", "Genève": "Geneva", "Genf": "Geneva", "Ginevra": "Geneva",
 "La Haya": "The Hague", "La Haye": "The Hague", "Den Haag": "The Hague", "L'Aia": "The Hague", "Haia": "The Hague",
 "Teherán": "Tehran", "Téhéran": "Tehran", "Teheran": "Tehran", "طهران": "Tehran", "德黑兰": "Tehran",
 "Bagdad": "Baghdad", "Bagdá": "Baghdad", "بغداد": "Baghdad",
 "Damasco": "Damascus", "Damas": "Damascus", "Damaskus": "Damascus", "دمشق": "Damascus",
 "Beirut": "Beirut", "Beyrouth": "Beirut", "بيروت": "Beirut",
 "El Cairo": "Cairo", "Le Caire": "Cairo", "Kairo": "Cairo", "Il Cairo": "Cairo", "القاهرة": "Cairo",
 "Trípoli": "Tripoli", "Tripolis": "Tripoli", "طرابلس": "Tripoli",
 "Jartum": "Khartoum", "Khartum": "Khartoum", "Cartum": "Khartoum", "الخرطوم": "Khartoum",
 "Mogadiscio": "Mogadishu", "Mogadischu": "Mogadishu", "مقديشو": "Mogadishu",
 "Estambul": "Istanbul", "İstanbul": "Istanbul", "Стамбул": "Istanbul", "伊斯坦布尔": "Istanbul",
 "Riad": "Riyadh", "Riyad": "Riyadh", "الرياض": "Riyadh",
 "Doha": "Doha", "Dubái": "Dubai", "Doubaï": "Dubai", "دبي": "Dubai",
 "Nueva Delhi": "New Delhi", "Neu-Delhi": "New Delhi", "Nuova Delhi": "New Delhi", "Nova Déli": "New Delhi",
 "Tokio": "Tokyo", "Tokio ": "Tokyo", "Токио": "Tokyo", "东京": "Tokyo",
 "Seúl": "Seoul", "Séoul": "Seoul", "Seul": "Seoul", "首尔": "Seoul",
 "Pionyang": "Pyongyang", "Pjöngjang": "Pyongyang", "平壤": "Pyongyang",
 "Taipéi": "Taipei", "Taipeh": "Taipei", "台北": "Taipei",
 "Varsovia": "Warsaw", "Varsovie": "Warsaw", "Warschau": "Warsaw", "Varsavia": "Warsaw", "Warszawa": "Warsaw",
 "Ciudad de México": "Mexico City", "Mexico": "Mexico City", "Città del Messico": "Mexico City",
 "São Paulo": "São Paulo", "Sao Paulo": "São Paulo", "Río de Janeiro": "Rio de Janeiro", "Rio de Janeiro": "Rio de Janeiro",
 "La Habana": "Havana", "La Havane": "Havana", "Havanna": "Havana", "L'Avana": "Havana",
 "Bogotá": "Bogotá", "Caracas": "Caracas", "Buenos Aires": "Buenos Aires", "Santiago de Chile": "Santiago",
}

# Region / bloc keywords (no country): name -> (lat, lon)
REGIONS = {
 "European Union": (50.85,4.35), "EU": (50.85,4.35), "Eurozone": (50.11,8.68), "NATO": (50.88,4.42), "Middle East": (29.0,42.0), "Gulf states": (25.0,50.0),
 "Balkans": (43.0,20.0), "Scandinavia": (62.0,15.0), "Central Asia": (43.0,68.0), "Southeast Asia": (8.0,108.0), "East Africa": (2.0,38.0), "West Africa": (10.0,-3.0),
 "Horn of Africa": (8.0,45.0), "Latin America": (-10.0,-60.0), "Caribbean": (17.0,-70.0), "Pacific Islands": (-10.0,170.0), "Indo-Pacific": (5.0,120.0), "ASEAN": (1.29,103.85), "African Union": (9.02,38.75), "BRICS": (0.0,60.0),
}

PUNCT = "“”\"'‘’(),;:!?[]«»…"
TOK_RE = re.compile(r"\S+")
MAX_SPAN = 5

def _norm_token(t: str) -> str:
    return t.strip(PUNCT).rstrip(".")

def _fold(s: str) -> str:
    return "".join(ch for ch in unicodedata.normalize("NFKD", s.lower()) if not unicodedata.combining(ch))

class Gazetteer:
    """Dictionary lookup over token n-grams (1..5 words): one pass per text, no per-alias regex."""
    CJK_RE = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]")

    def __init__(self):
        self.table = {}   # key -> (kind, key_id, weight)
        self.cjk = {}     # Chinese/Japanese/Korean names: no spaces, so matched as substrings
        def add(alias, kind, key, w):
            alias = " ".join(_norm_token(t) for t in alias.split())
            if not alias:
                return
            if self.CJK_RE.search(alias):
                self.cjk.setdefault(alias, (kind, key, w))
            elif alias in CASE_SENSITIVE_ALIASES:
                self.table.setdefault("cs:" + alias, (kind, key, w))
            else:
                self.table.setdefault(_fold(alias), (kind, key, w))
        for city in CITIES:
            add(city, "city", city, 2.5)
        for alias, city in CITY_ALIASES.items():
            if city in CITIES:
                add(alias, "city", city, 2.5)
        for c in COUNTRIES:
            code, name = c[0], c[1]
            add(name, "country", code, 3.0)
            for a in (c[9] or "").split("|"):
                if a.strip():
                    add(a.strip(), "country", code, 1.5)
        for reg in REGIONS:
            add(reg, "region", reg, 1.0)

    def scan(self, text: str):
        c = Counter()
        if not text:
            return c
        if self.cjk and self.CJK_RE.search(text):
            for alias, (kind, key, w) in self.cjk.items():
                if alias in text:
                    c[(kind, key)] += w
        toks = [_norm_token(t) for t in TOK_RE.findall(text)]
        n = len(toks)
        i = 0
        while i < n:
            hit = None
            for span in range(min(MAX_SPAN, n - i), 0, -1):
                raw = " ".join(toks[i:i + span])
                if not raw:
                    continue
                v = self.table.get("cs:" + raw) or self.table.get(_fold(raw))
                if v:
                    hit = (v, span); break
            if hit:
                (kind, key, w), span = hit
                nxt = toks[i + span] if i + span < n else ""
                # "Milan Pradhan", "Paris Hilton": a single-token place followed by another capitalised
                # word is usually part of somebody's name, not a dateline.
                if span == 1 and kind == "city" and nxt[:1].isupper() and nxt.isalpha():
                    i += 1
                    continue
                c[(kind, key)] += w
                i += span
            else:
                i += 1
        return c


    # A country whose name is a prefix of a bigger neighbour's is constantly mistaken for it.
    # Keep the smaller one only when something specific to it is actually mentioned.
    OVERSHADOWED = {
        "NE": ("NG", ("niamey", "nigerien", "tiani", "tchiani", "niger republic")),
        "CG": ("CD", ("brazzaville", "sassou", "congo-brazzaville")),
        "DO": ("DM", ("roseau",)),
    }

    def _disambiguate(self, countries, text_folded):
        for small, (big, markers) in self.OVERSHADOWED.items():
            if small in countries and big in countries and not any(m in text_folded for m in markers):
                countries[big] += countries.pop(small)
        return countries

    def resolve(self, title: str, body: str, source_country: str | None):
        """Return (locations, countries) where locations is a list of dicts with lat/lon and countries a weighted dict."""
        weights = self.scan(title)
        for k, v in self.scan(body).items():
            weights[k] += 0.5 * v          # title mentions count double
        countries = Counter()
        locs = []
        folded = _fold(f"{title} {body}")
        for (kind, key), w in weights.items():
            if kind == "country":
                countries[key] += w
                c = COUNTRY_BY_CODE[key]
                locs.append({"name": c[1], "lat": c[3], "lon": c[4], "country": key, "weight": w, "kind": "country"})
            elif kind == "city":
                lat, lon, cc = CITIES[key]
                if cc:
                    countries[cc] += w
                locs.append({"name": key, "lat": lat, "lon": lon, "country": cc, "weight": w + 0.5, "kind": "city"})
            else:
                lat, lon = REGIONS[key]
                locs.append({"name": key, "lat": lat, "lon": lon, "country": None, "weight": w, "kind": "region"})
        if not locs and source_country and source_country in COUNTRY_BY_CODE:
            c = COUNTRY_BY_CODE[source_country]
            locs.append({"name": c[1], "lat": c[3], "lon": c[4], "country": source_country, "weight": 0.5, "kind": "source-country"})
            countries[source_country] += 0.5
        self._disambiguate(countries, folded)
        locs = [l for l in locs if l["kind"] != "country" or l["country"] in countries]
        locs.sort(key=lambda d: -d["weight"])
        return locs, countries

GAZETTEER = Gazetteer()
GAZ_VERSION = hashlib.md5(repr(sorted(GAZETTEER.table)).encode()).hexdigest()[:10]
