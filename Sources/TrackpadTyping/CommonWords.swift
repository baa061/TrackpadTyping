import Foundation

/// A frequency-ordered core English vocabulary.
///
/// Rank carries the language model: position in this list is the word's prior.
/// It exists because the only word list guaranteed to be on a Mac is
/// /usr/share/dict/web2 (Webster's 2nd), which is ~198k entries of largely
/// archaic vocabulary with no frequency information at all. Decoding against
/// that flat is actively worse than decoding against a good 1k list, because
/// obscure words sit in the gaps between common ones and win on shape.
enum CommonWords {
    static let ordered: [String] = raw.split(separator: " ").map(String.init)

    private static let raw = """
the be to of and a in that have i it for not on with he as you do at this but his by from \
they we say her she or an will my one all would there their what so up out if about who get \
which go me when make can like time no just him know take people into year your good some \
could them see other than then now look only come its over think also back after use two how \
our work first well way even new want because any these give day most us is are was were been \
being has had do does did doing say says said get gets got go goes going went make makes made \
know knows knew think thinks thought take takes took see sees saw come comes came want wants \
wanted use uses used find finds found give gives gave tell tells told work works worked call \
calls called try tries tried ask asks asked need needs needed feel feels felt become becomes \
became leave leaves left put puts mean means meant keep keeps kept let lets begin begins began \
seem seems seemed help helps helped talk talks talked turn turns turned start starts started \
show shows showed hear hears heard play plays played run runs ran move moves moved live lives \
lived believe believes believed bring brings brought happen happens happened write writes wrote \
sit sits sat stand stands stood lose loses lost pay pays paid meet meets met include includes \
continue continues set sets learn learns learned change changes changed lead leads led \
understand understands understood watch watches watched follow follows followed stop stops \
stopped create creates created speak speaks spoke read reads spend spends spent grow grows grew \
open opens opened walk walks walked win wins won offer offers offered remember remembers love \
loves loved consider considers appear appears buy buys bought wait waits waited serve serves \
die dies died send sends sent build builds built stay stays stayed fall falls fell cut cuts \
reach reaches reached kill kills killed remain remains suggest suggests raise raises raised \
pass passes passed sell sells sold require requires report reports reported decide decides \
pull pulls pulled return returns returned explain explains hope hopes hoped develop develops \
carry carries carried break breaks broke receive receives agree agrees agreed support supports \
hit hits cover covers covered catch catches caught draw draws drew choose chooses chose \
person year way day thing man world life hand part child eye woman place work week case point \
government company number group problem fact home water room mother area money story month lot \
right study book job word business issue side kind head house service friend father power hour \
game line end member law car city community name president team minute idea kid body \
information back parent face others level office door health art war history party result \
change morning reason research girl guy moment air teacher force education foot boy age policy \
process music market sense nation plan college interest death experience effect use class \
control care field development role effort rate heart drug show leader light voice wife police \
mind price report decision son view relationship town road arm difference value building \
action model season society tax director position player record paper space ground form event \
official matter center couple site project activity star table need court produce edge past \
writer top step morning material airport type attack sport range board rest amount cost list \
chance figure man model source security news series film industry account level truth answer \
sound piece energy phone future skin design method sign customer computer network file screen \
message data system software program device version project client server user page site link \
email address phone number code text image video audio photo camera window button menu list \
search filter sort save load open close print share upload download install update delete \
folder document report chart graph table row column field value input output result total \
good new first last long great little own other old right big high different small large next \
early young important few public bad same able best better sure free true low late hard whole \
simple clear easy strong possible real full local social national personal general natural \
special common recent political economic international human physical financial legal medical \
similar available current single major serious close short direct present certain likely \
happy nice fine cold warm hot cool dark light heavy quick slow quiet loud clean dirty safe \
very just now also only then here there when where how why what who which than more most \
much many well even still back down out up off over under again once too both each every \
between through during before after above below around behind beside near far always never \
often sometimes usually already yet almost enough perhaps maybe really quite rather instead \
however therefore because since while until unless although though whether either neither \
please thanks thank hello sorry okay yes yeah sure right wrong true false left right up down \
today tomorrow yesterday tonight morning afternoon evening night week weekend month year hour \
minute second time date day monday tuesday wednesday thursday friday saturday sunday january \
february march april may june july august september october november december spring summer \
autumn winter one two three four five six seven eight nine ten eleven twelve twenty thirty \
forty fifty hundred thousand million billion half quarter double single first second third \
food water coffee tea milk bread meat fish rice fruit apple orange banana dinner lunch \
breakfast kitchen table chair bed window floor wall roof garden street train bus plane car \
bike walk drive ride travel trip hotel airport station ticket bag key door lock phone laptop \
mouse keyboard screen desk chair office meeting call email text message reply send receive \
please help thanks sorry maybe okay great awesome cool nice good bad fine well done ready \
about above across after against along among around because before behind below beneath \
beside besides between beyond despite down during except inside into near onto outside over \
since through throughout toward under underneath until upon within without \
another anyone anything anywhere everyone everything everywhere nobody nothing nowhere someone \
something somewhere myself yourself himself herself itself ourselves themselves \
actually basically certainly clearly completely definitely easily especially exactly finally \
generally hardly immediately mainly nearly obviously particularly probably quickly recently \
simply slightly suddenly totally usually virtually widely \
add allow appreciate arrive attend avoid begin belong check choose claim compare complete \
confirm connect contain deliver depend describe discover discuss enjoy enter exist expect \
express extend finish focus force gather handle happen imagine improve increase indicate \
introduce involve join judge manage measure mention notice obtain occur perform prefer \
prepare present prevent produce protect provide publish realize recognize reduce refer reflect \
refuse relate release remove repeat replace represent respond result reveal review search \
select separate settle share solve sort stress submit succeed suggest supply survive teach \
test thank throw touch train treat trust visit vote wonder worry write
"""
}
