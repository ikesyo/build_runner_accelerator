import 'package:json_annotation/json_annotation.dart';

part 'model_095.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model095 {
  const Model095({required this.id, required this.value});

  final int id;
  final String value;

  factory Model095.fromJson(Map<String, dynamic> json) =>
      _$Model095FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model095ToJson(this);
}
