import 'package:json_annotation/json_annotation.dart';

part 'model_405.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model405 {
  const Model405({required this.id, required this.value});

  final int id;
  final String value;

  factory Model405.fromJson(Map<String, dynamic> json) =>
      _$Model405FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model405ToJson(this);
}
