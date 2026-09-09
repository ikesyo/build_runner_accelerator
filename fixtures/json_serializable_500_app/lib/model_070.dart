import 'package:json_annotation/json_annotation.dart';

part 'model_070.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model070 {
  const Model070({required this.id, required this.value});

  final int id;
  final String value;

  factory Model070.fromJson(Map<String, dynamic> json) =>
      _$Model070FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model070ToJson(this);
}
