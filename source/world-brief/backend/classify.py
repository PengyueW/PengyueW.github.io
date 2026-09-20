"""Topic taxonomy: 23 focus areas, weak-supervision keyword rules and seed training headlines.

The rules give high-precision weak labels; the seed headlines anchor each class; the local model
(backend/ml.py) generalises from both to the whole corpus.
"""
import hashlib
import re

from .textutil import strip_quoted

CATEGORIES = [
 ("war", "War & military conflict", 15),
 ("economy", "Economic policy & markets", 9),
 ("disaster", "Disasters & emergencies", 12),
 ("regulation", "Regulation & rule changes", 6),
 ("international", "International relations & diplomacy", 9),
 ("political-change", "Political change (elections, coups, resignations)", 11),
 ("social", "Social reports & society", 5),
 ("lifestyle", "Lifestyle & culture hits", 3),
 ("state-visit", "State visits, announcements & talks", 7),
 ("development", "New developments & infrastructure", 4),
 ("discovery", "Discoveries & inventions", 6),
 ("technology", "New technologies", 6),
 ("opinion", "Popular opinion & polls", 4),
 ("trending", "Most discussed right now", 5),
 ("education-jobs", "Education & job opportunities", 4),
 ("art", "Art & culture", 3),
 ("history", "History & heritage", 3),
 ("trend", "New trends", 3),
 ("conflict-live", "Heated conversations & live conflicts", 8),
 ("politics-law", "Politics & law", 6),
 ("military", "Military affairs & arms", 8),
 ("instability", "Regional instability & unrest", 10),
 ("other", "Other noteworthy", 2),
]
CATEGORY_LABELS = {c[0]: c[1] for c in CATEGORIES}
CATEGORY_WEIGHT = {c[0]: c[2] for c in CATEGORIES}
CATEGORY_IDS = [c[0] for c in CATEGORIES if c[0] != "other"]

# Multiplier on an event's relevance by primary category: hard news outranks entertainment at equal coverage.
CATEGORY_GRAVITY = {
 "war": 1.25, "instability": 1.2, "disaster": 1.2, "political-change": 1.15, "international": 1.1, "economy": 1.1, "military": 1.1,
 "regulation": 1.0, "politics-law": 1.0, "state-visit": 1.0, "conflict-live": 1.0, "social": 0.95, "development": 0.95,
 "discovery": 0.95, "technology": 0.95, "education-jobs": 0.9, "opinion": 0.85, "trending": 0.8, "history": 0.8,
 "art": 0.75, "trend": 0.75, "lifestyle": 0.6, "other": 0.7,
}

# Keyword rules (regex fragments, matched case-insensitively on title + summary). Multilingual where cheap.
RULES = {
 "war": r"\b(war|warfare|airstrikes?|air strikes?|shelling|missile|missiles|drone strikes?|drones? attack|offensive|frontline|front line|invasion|invaded|bombard|bombing|artillery|ceasefire|cease-fire|truce|hostilities|troops|battalion|combat|killed in (an )?(attack|strike)|guerre|guerra|krieg|война|ejército|armée|hostages?)\b",
 "military": r"\b(military|army|navy|air force|defen[cs]e (ministry|budget|spending|pact)|pentagon|nato|warship|frigate|destroyer|submarine|fighter jets?|f-?35|f-?16|missile (test|launch|defen[cs]e)|arms (deal|sales?|exports?)|weapons?|ammunition|conscription|mobili[sz]ation|joint exercises?|drills?|militaire|militar|militär|военн)\b",
 "instability": r"\b(died in custody|deaths in custody|custodial death|detainees|shooting|shootings|gunman|gunmen|shot dead|opened fire|stabbing|knife attack|bomb(ing)? attack|suicide bomb(er|ing)?|car bomb|unrest|riots?|coup|junta|insurgen(cy|ts)|militants?|militia|separatists?|rebels?|uprising|clashes|crackdown|martial law|state of emergency|curfew|kidnapp(ed|ing)|abduct|massacre|terror(ist|ism)?|extremist|jihadist|al[- ]qaeda|isis|isil|islamic state|gang violence|cartel|sectarian|ethnic violence|displaced|refugees?|famine|humanitarian crisis)\b",
 "conflict-live": r"\b(protests?|protesters|demonstrat(ion|ors)|strike action|general strike|walkout|standoff|clash(es|ed)?|backlash|outrage|boycott|controvers(y|ial)|row over|spar(s|red)? over|feud|showdown|escalat(es|ion|ing)|tensions? (rise|flare|mount)|blockade|siege)\b",
 "economy": r"\b(economy|economic|gdp|inflation|recession|interest rates?|rate (cut|hike|decision)|central bank|federal reserve|ecb|tariffs?|trade (war|deal|deficit|surplus|talks)|stock market|stocks|shares|bond yields?|markets? (rally|fall|tumble|plunge|slump)|budget|fiscal|tax(es|ation)?|debt|deficit|imf|world bank|currency|exchange rate|exports?|imports?|unemployment|jobs report|wages|oil prices?|opec|crude|subsid(y|ies)|stimulus|austerity|bailout|bankrupt(cy)?|layoffs?|inflación|économie|wirtschaft|экономик|投資|経済|经济)\b",
 "regulation": r"\b(regulat(ion|ions|or|ors|ory|e|ed)|ban(s|ned)? (on|the)|bans?\b|outlaw|legislation|bill (passes|passed|signed|approved)|law (passed|signed|takes effect)|new (law|rules?)|rules? (on|for|against)|antitrust|anti-trust|competition (authority|commission)|fine[ds]? (\$|€|£)|compliance|licen[cs]e|sanction(s|ed)|export controls?|data protection|gdpr|privacy law|crackdown on|permit|zoning|tobacco|vaping|age verification|reglament|règlement|verordnung)\b",
 "international": r"\b(diplomat(ic|s|y)?|foreign minist(er|ry)|secretary of state|ambassador|embassy|bilateral|multilateral|alliance|allies|treaty|accord|agreement (with|between)|sanctions?|united nations|un security council|g7|g20|brics|summit|relations (with|between)|ties (with|between)|recogni[sz]es?|expel(s|led)|envoy|peace talks|negotiat(ions|ors)|mediat(ion|ors?)|diplomatie|diplomacia|außenminister)\b",
 "political-change": r"\b(election(s)?|electoral|ballot|vote|votes|voting|voters|polls? (open|close)|referendum|landslide|runoff|run-off|coalition|prime minister|president(-elect)?|resign(s|ed|ation)|sworn in|inaugurat(ed|ion)|impeach(ment|ed)?|no-confidence|no confidence|cabinet reshuffle|reshuffle|dissolv(es|ed) parliament|snap election|coup|ousted|toppled|takes office|steps down|wins? (the )?(election|presidency|vote)|élection|elección|wahl|выборы|選挙)\b",
 "politics-law": r"\b(parliament|congress|senate|house of (commons|representatives)|lawmakers?|mps?\b|legislat(ure|ors?)|supreme court|constitutional court|high court|court (rules|ruled|rejects|upholds)|ruling|verdict|indict(ed|ment)|charged with|convicted|sentenced|trial|prosecutors?|lawsuit|sues?|judge|attorney general|justice ministry|governor|mayor|opposition (party|leader)|ruling party|manifesto|policy|policies|bill\b|veto|executive order|constitution(al)?|tribunal|corruption|bribery|scandal)\b",
 "disaster": r"\b(shark attack|shark kills|mauled by|crocodile attack|elephant attack|drowned|drowning|stampede|earthquake|quake|magnitude|tsunami|hurricane|typhoon|cyclone|tornado|flood(s|ing|ed)?|landslide|mudslide|wildfire|bushfire|forest fire|blaze|volcano|volcanic|eruption|drought|heatwave|heat wave|storm|blizzard|avalanche|explosion|blast|collapse[ds]?|derail(ed|ment)|plane crash|crash(es|ed)? (kills|killing)|shipwreck|capsized|sinks|outbreak|epidemic|pandemic|cholera|ebola|mpox|bird flu|hiv|aids epidemic|malaria|measles|dengue|health emergency|declares? (a )?(state of )?emergency|public health emergency|famine declared|death toll|casualties|rescue|evacuat(ed|ion|ions)|séisme|terremoto|inondation|erdbeben|землетрясение|地震)\b",
 "social": r"\b(inequality|poverty|homeless(ness)?|housing crisis|rent(s)? (rise|soar)|migration|migrants?|asylum|immigration|census|population|birth rate|ageing|aging population|pension(s|ers)?|welfare|healthcare|health care|hospital(s)?|public health|mental health|abortion|lgbt|gender|racism|discrimination|human rights|police (shooting|brutality)|crime rate|domestic violence|drug (use|deaths|overdose)|opioid|survey finds|study finds|report finds|social media harms?)\b",
 "lifestyle": r"\b(lifestyle|wellness|fitness|diet|recipe|fashion week|fashion|beauty|travel|tourism|tourists?|holiday|restaurant|michelin|cuisine|celebrit(y|ies)|box office|blockbuster|streaming|netflix|k-pop|album|concert|tour dates|sequel|prequel|spin-?off|reboot|starring|stars in|cast as|returns? as|secuela|película|filme|trailer|premiere|season \d|episode|series finale|fifa|uefa|concacaf|caf\b|afc\b|olympic committee|handball|volleyball|basketball|badminton|athletics|swimming|gymnastics|asian games|asiad|commonwealth games|sevens|friendly match|group stage|medal table|world cup|olympic(s)?|championship|grand prix|premier league|ligue 1|la liga|serie a|bundesliga|champions league|europa league|nba|nfl|nhl|mlb|cricket|tennis|golf|rugby|formula 1|f1\b|marathon|wedding|royal family|prince|princess|duchess|footballer|striker|midfielder|goalkeeper|coach|manager sacked|transfer window|match(es|day)?|fixture|playoffs?|semi-?final|quarter-?final|final\b|wicket|innings|medal|athlete|tournament|celebrity|actor|actress|singer|rapper|reality tv|bafta|emmy|grammys?|billboard)\b",
 "state-visit": r"\b(state visit|official visit|visits? (to )?(washington|beijing|moscow|brussels|paris|london|delhi|tokyo|berlin)|welcomed|receives? (president|prime minister|king|chancellor)|hosts? (talks|summit|leaders)|meets? (with )?(president|prime minister|counterpart|leader|king|chancellor|xi|putin|trump|modi)|talks (with|between|in)|phone call|(president|prime minister|chancellor|minister|king|government|leader|premier|secretary)[^.]{0,40}(announce[sd]?|declare[sd]?|unveil(s|ed)?|pledge[sd]?|vow(s|ed)?)|joint statement|press conference|address(es|ed) (the )?nation|keynote speech)\b",
 "development": r"\b(infrastructure|high-speed rail|railway|metro line|highway|bridge|port expansion|airport (opens|expansion)|power plant|nuclear plant|solar farm|wind farm|pipeline|dam|construction|megaproject|smart city|housing project|broadband|5g rollout|investment of|invests? (\$|€|£)|billion (investment|project|deal)|factory|plant opens|groundbreaking|inaugurat(es|ed) (a |the )?(new )?(plant|bridge|line|port|airport)|development (project|plan|bank))\b",
 "discovery": r"\b(discover(y|ed|s)|breakthrough|scientists? (find|found|say|develop)|researchers? (find|found|develop)|study (shows|reveals)|new species|fossil|archaeolog(y|ists|ical)|excavat|telescope|nasa|esa|space (mission|probe|station|launch)|rocket launch|spacex|mars|moon (mission|landing)|asteroid|exoplanet|black hole|quantum|crispr|gene (therapy|editing)|vaccine (trial|approved)|clinical trial|cure|invention|invent(ed|ors?)|patent|nobel)\b",
 "technology": r"\b(technolog(y|ies)|artificial intelligence|\bai\b|chatbot|large language model|machine learning|robot(s|ics)?|semiconductor|chips?\b|nvidia|tsmc|intel\b|apple\b|google|microsoft|meta\b|amazon|openai|tesla|electric vehicles?|ev\b|evs\b|battery|cybersecurity|cyberattack|cyber attack|hack(ed|ers?)|ransomware|data breach|software|app\b|smartphone|iphone|android|5g|6g|satellite|starlink|drone (delivery|technology)|fintech|crypto(currency)?|bitcoin|blockchain|autonomous|self-driving|nuclear fusion|hydrogen|tech giants?)\b",
 "opinion": r"\b(poll(s|ing)? (shows?|finds?|suggests?)|opinion poll|approval rating|survey (shows|finds|says)|percent of (people|voters|americans|britons|respondents)|% of (people|voters|respondents)|public opinion|majority (of )?(people|voters|say|support|oppose)|popularity|sentiment|editorial|op-ed|opinion:|comment:|analysis:)\b",
 "trending": r"\b(viral|goes viral|trending|trends? on|x users|twitter|tiktok|instagram|youtube|reddit|meme|internet (reacts|erupts)|social media (storm|frenzy|reacts)|everyone is talking|sparks debate|hashtag)\b",
 "education-jobs": r"\b(universit(y|ies)|college|school (funding|fees|curriculum|reform|system|places|leavers)|schools (reopen|close|struggle)|students?|teachers?|tuition|scholarship(s)?|exam(s|ination)?|curriculum|literacy|graduates?|degree|phd|hiring|recruit(ing|ment)|job (openings|fair|market|cuts|creation)|jobs? (created|added|lost)|employment|apprenticeship|vacancies|visa (programme|program|scheme)|work permit|skilled workers?|labour market|labor market|internship|éducation|educación|bildung|образование)\b",
 "art": r"\b(art\b|arts\b|artist(s)?|museum|gallery|exhibition|exhibit|painting|sculpture|biennale|theatre|theater|opera|ballet|orchestra|symphony|literature|novel(ist)?|poet(ry)?|booker|pulitzer|film festival|cannes|venice film|oscars?|academy awards?|grammy|documentary|architecture|heritage site|unesco|cultural|culture|kultur|cultura|culture)\b",
 "history": r"\b(anniversary|commemorat(es|ion)|remembrance|memorial|centenary|centennial|historians?|historic(al)?|archives?|declassified|world war|ww2|wwii|holocaust|genocide (recognition|memorial)|colonial|empire|dynasty|ancient|medieval|archaeolog|restitution|repatriat(ion|ed) (artifacts|remains)|monument)\b",
 "trend": r"\b(trend(s|ing)?|new trend|growing trend|rise of|boom in|surge in|craze|fad|gen z|millennials?|the new normal|shift toward|increasingly|more and more|record number of|popularity of|demand for)\b",
}
_COMPILED = {k: re.compile(v, re.I) for k, v in RULES.items()}
RULES_VERSION = hashlib.md5(repr(sorted(RULES.items())).encode()).hexdigest()[:10]

# Categories whose keywords are commonly hit by the *title of a work* ("World War Z", "The Crown").
QUOTE_SENSITIVE = {"war", "military", "instability", "disaster", "conflict-live", "political-change"}

def rule_scores(text: str):
    """Return {category: number of rule hits} for categories with at least one hit."""
    out = {}
    if not text:
        return out
    unquoted = None
    for cat, rx in _COMPILED.items():
        target = text
        if cat in QUOTE_SENSITIVE:
            if unquoted is None:
                unquoted = strip_quoted(text)
            target = unquoted
        n = len(rx.findall(target))
        if n:
            out[cat] = n
    return out

def article_hits(a):
    """Rule hits for an article: {'all': {cat: n}, 'title': {cat: n}}. Uses the cached DB column when present."""
    cached = a.get("_rules")
    if cached is not None:
        return cached
    hits = {"all": rule_scores(f"{a.get('title','')} {(a.get('summary') or '')[:500]}"), "title": rule_scores(a.get("title", ""))}
    a["_rules"] = hits
    return hits

# Seed headlines (hand-written, English) anchoring each category for the local classifier.
SEED = {
 "war": ["Russian missiles hit Kyiv overnight as air raid sirens sound across Ukraine", "Israeli airstrikes kill dozens in Gaza as ceasefire talks stall", "Sudan's army and RSF trade artillery fire in El Fasher", "Front line shifts as Ukrainian forces counterattack near Pokrovsk", "Houthi drone attack targets ship in Red Sea", "Fighting intensifies in eastern Congo as M23 rebels advance on Goma", "Myanmar junta airstrike hits village, dozens dead", "Hezbollah and Israel exchange fire across Lebanon border", "Ethiopian troops clash with militia in Amhara region", "Casualties mount as offensive enters third week"],
 "military": ["Pentagon requests record defence budget for next year", "NATO allies agree to raise military spending target", "China conducts live-fire drills around Taiwan", "Navy commissions new nuclear submarine", "Government approves $5 billion arms deal for fighter jets", "Army announces conscription expansion amid regional tensions", "Joint military exercises begin in the Baltic Sea", "North Korea tests intercontinental ballistic missile", "Defence ministry unveils hypersonic missile programme", "US to deploy additional troops to the Middle East"],
 "instability": ["Coup leaders dissolve parliament after seizing power", "Militants kill 30 in attack on northern Nigeria village", "Gang violence forces thousands to flee Port-au-Prince", "Insurgents ambush convoy in Sahel as region destabilises", "Riots erupt in capital after disputed vote", "Kidnappings surge as security collapses in border region", "Government declares state of emergency after deadly unrest", "Jihadist attack on military base leaves dozens dead", "Separatist rebels seize town in the east", "Famine warning issued as fighting displaces half a million"],
 "conflict-live": ["Tens of thousands protest pension reform in Paris", "Farmers block highways in nationwide strike", "Clashes between police and demonstrators outside parliament", "Backlash grows over controversial immigration remarks", "Union walkout paralyses rail network for a third day", "Heated debate as lawmakers spar over budget cuts", "Boycott campaign spreads after company's statement", "Standoff continues at occupied university campus", "Tensions flare at border crossing after shooting", "Public outrage over minister's comments forces apology"],
 "economy": ["Central bank holds interest rates as inflation cools", "Stocks tumble as tariff fears rattle global markets", "Government unveils budget with sweeping tax cuts", "IMF warns of slowing growth in emerging economies", "Oil prices jump after OPEC output cut", "Unemployment falls to lowest level in a decade", "Currency hits record low against the dollar", "Trade deficit widens as exports slump", "Finance minister announces stimulus package for households", "Tech giant announces layoffs of 10,000 workers"],
 "regulation": ["EU fines tech giant €1.2 billion for antitrust breach", "Government bans single-use plastics from next year", "New rules require age verification for social media", "Regulator blocks merger over competition concerns", "Parliament passes sweeping data protection law", "Central bank tightens rules on mortgage lending", "Country outlaws vaping products for under-25s", "New export controls target advanced chips", "Aviation authority grounds aircraft model after inspections", "Ministry issues new licensing rules for ride-hailing apps"],
 "international": ["Foreign ministers meet to discuss sanctions on Russia", "Two countries restore diplomatic ties after decade-long rift", "UN Security Council votes on ceasefire resolution", "Embassy staff expelled in escalating diplomatic row", "G20 summit ends with joint statement on climate finance", "Peace talks resume in Doha with mediators present", "Ambassador recalled after spy allegations", "Trade agreement signed between the EU and Mercosur", "Countries sign defence pact amid tensions with neighbour", "Envoy visits capital to ease strained relations"],
 "political-change": ["Opposition wins landslide in parliamentary election", "Prime minister resigns after coalition collapses", "President sworn in after disputed runoff", "Government falls in no-confidence vote", "Snap election called after budget defeat", "Cabinet reshuffle brings new foreign minister", "Referendum approves constitutional changes", "Military ousts president in overnight coup", "Voters head to polls in tight presidential race", "New leader takes office promising reform"],
 "politics-law": ["Supreme court strikes down controversial law", "Former president indicted on corruption charges", "Parliament debates bill to reform electoral system", "Judge sentences ex-minister to eight years for bribery", "Lawmakers pass budget after marathon session", "Governor signs executive order on housing", "Prosecutors charge official in embezzlement case", "Constitutional court rules on presidential term limits", "Senate committee opens inquiry into scandal", "Attorney general sues company over consumer fraud"],
 "disaster": ["Magnitude 7.1 earthquake strikes off the coast, tsunami warning issued", "Typhoon makes landfall, hundreds of thousands evacuated", "Wildfires rage across region as heatwave continues", "Floods kill dozens and displace thousands", "Death toll rises after building collapse", "Volcano erupts forcing evacuations", "Cholera outbreak spreads in refugee camps", "Plane crash kills 60 on domestic flight", "Landslide buries village after heavy rains", "Explosion at chemical plant injures dozens"],
 "social": ["Report finds child poverty at highest level in 20 years", "Housing crisis pushes rents to record highs", "Study shows widening inequality since the pandemic", "Migrant arrivals reach new high as asylum system strains", "Hospitals warn of staffing shortages this winter", "Survey reveals rising loneliness among young adults", "Pension reform sparks concern among older workers", "Police shooting prompts calls for reform", "Birth rate falls to record low", "Human rights group documents abuses in detention centres"],
 "lifestyle": ["City named world's best food destination", "Fashion week opens with sustainable collections", "Pop star's world tour breaks ticket sales record", "Box office hit smashes opening weekend record", "Tourism rebounds as visitors return to island", "Michelin guide adds ten new restaurants", "National team wins championship after dramatic final", "Streaming series becomes most-watched show of the year", "Marathon draws record 50,000 runners", "Royal wedding draws millions of viewers"],
 "state-visit": ["President arrives in Beijing for three-day state visit", "Leaders hold talks on trade and security in Washington", "Prime minister announces new climate targets at summit", "King welcomes visiting head of state at palace", "Chancellor meets counterpart to discuss energy cooperation", "President addresses the nation on economic plan", "Foreign minister to visit Moscow for talks next week", "Joint press conference follows bilateral meeting", "Leaders pledge deeper cooperation in joint statement", "Premier unveils infrastructure plan in keynote speech"],
 "development": ["High-speed rail line opens linking two major cities", "Country breaks ground on largest solar farm in Africa", "New deep-water port to boost regional trade", "Government approves $10 billion infrastructure plan", "Nuclear power plant construction begins", "New metro line opens after decade of construction", "Dam project nears completion despite protests", "Factory opening to create 3,000 jobs", "Broadband rollout reaches rural communities", "Smart city megaproject unveiled in the desert"],
 "discovery": ["Scientists discover new species in deep-sea trench", "Archaeologists unearth 3,000-year-old tomb", "Telescope captures first image of distant exoplanet", "Researchers announce breakthrough in fusion energy", "Gene therapy cures rare disease in trial", "Fossil find rewrites history of early mammals", "Probe returns asteroid samples to Earth", "Study reveals mechanism behind ageing cells", "Nobel prize awarded for quantum research", "New vaccine shows 90% efficacy in trial"],
 "technology": ["Company unveils new AI model that codes and reasons", "Chipmaker announces next-generation semiconductor", "Ransomware attack cripples hospital network", "Electric vehicle sales overtake petrol cars in market", "Robotics firm shows humanoid working in factory", "Tech giant faces scrutiny over AI training data", "Startup launches satellite internet service", "Smartphone maker releases foldable device", "Cyberattack hits government systems", "Bitcoin surges past record high"],
 "opinion": ["Poll shows majority oppose new pension law", "Approval rating for president falls to 35 percent", "Survey finds most voters worried about cost of living", "Public opinion shifts on immigration, poll finds", "Editorial: the government has run out of ideas", "Opinion: why the ceasefire will not hold", "Majority of citizens support joining the alliance, survey says", "Analysis: what the election result means", "Poll suggests tight race ahead of vote", "Sentiment sours as households feel the squeeze"],
 "trending": ["Video of politician's gaffe goes viral", "Social media erupts over referee's decision", "Hashtag trends worldwide after singer's statement", "TikTok challenge sparks safety warnings", "Internet reacts to surprise announcement", "Meme spreads after awkward summit moment", "Viral clip prompts investigation", "Everyone is talking about the finale", "Debate rages online over new policy", "Reddit users uncover details of leaked document"],
 "education-jobs": ["Universities face funding cuts as enrolment falls", "Government launches scholarship programme for engineers", "Teachers strike over pay and class sizes", "Country opens visa scheme for skilled workers", "Exam results show gap between rich and poor students", "Tech firms announce thousands of new jobs", "New apprenticeship scheme targets youth unemployment", "School curriculum overhaul adds coding classes", "Graduate hiring slows as companies cut budgets", "Foreign students face new work permit rules"],
 "art": ["Museum opens landmark exhibition of Renaissance masters", "Film wins top prize at Cannes", "Booker prize goes to debut novelist", "Biennale opens with focus on climate", "Orchestra premieres new symphony", "Stolen painting recovered after 30 years", "UNESCO adds sites to world heritage list", "Theatre festival draws record crowds", "Sculpture unveiled in city square", "Documentary wins Oscar for best feature"],
 "history": ["Nation marks 80th anniversary of liberation", "Declassified files shed light on Cold War operation", "Museum returns looted artefacts to former colony", "Historians uncover letters from wartime leader", "Memorial unveiled for victims of massacre", "Centenary of independence celebrated", "Archive reveals secret negotiations", "Monument restored after years of neglect", "Country apologises for colonial-era abuses", "Excavation reveals medieval city beneath square"],
 "trend": ["Gen Z drives boom in secondhand fashion", "Rise of remote work reshapes city centres", "Surge in demand for electric bikes", "More young people shun alcohol, data shows", "Craze for collectible toys sweeps Asia", "Record number of workers switch to four-day week", "Shift toward plant-based diets accelerates", "Popularity of solo travel grows", "Trend of quiet quitting spreads", "Boom in pickleball courts across suburbs"],
}
