//
//  ZPDescobertas.h
//  tocaTintas
//
//  A janela «A seguir»: o que a estação tem alinhado para tocar.
//  (O nome do ficheiro vem de quando a janela mostrava as descobertas.)
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Quem sabe da estação que está a tocar (o ViewController). A chave de uma
/// faixa é o caminho do ficheiro ou «musica:<persistent ID>».
@protocol ZPFonteDaEstacao <NSObject>
/// As faixas alinhadas para tocar depois da que se ouve, por ordem; cada uma
/// como (chave, artista, título, álbum, «1» se está marcada para tocar ou «0»
/// se não). nil se não houver estação a tocar.
- (nullable NSArray<NSArray<NSString *> *> *)proximasDaEstacao;
/// A fila como ficou na janela: todas as chaves, pela ordem nova, e as que
/// ficaram desmarcadas (não tocam, mas continuam à vista). `subiu` é a faixa
/// que acabou de ser arrastada para cima e `desceu` a que foi arrastada para
/// baixo, se foi isso que aconteceu.
- (void)filaDaEstacaoPassaASer:(NSArray<NSString *> *)chaves desmarcadas:(NSSet<NSString *> *)desmarcadas
                         subiu:(nullable NSString *)subiu desceu:(nullable NSString *)desceu;
@end

/// Uma tabela só: uma caixa de marca por faixa (marcada à partida; desmarcada,
/// a faixa não toca), artista, título e álbum. As linhas arrastam-se para
/// mudar a ordem por que tocam.
@interface ZPDescobertas : NSWindowController

- (instancetype)initComFonte:(id<ZPFonteDaEstacao>)fonte;

/// Traz a janela para a frente e refaz a tabela.
- (void)mostrar;

/// Refaz a tabela se a janela estiver à vista (mudou a faixa ou a estação).
- (void)refazerSeAVista;

@end

NS_ASSUME_NONNULL_END
