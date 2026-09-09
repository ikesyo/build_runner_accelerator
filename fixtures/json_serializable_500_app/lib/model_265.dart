import 'package:json_annotation/json_annotation.dart';

part 'model_265.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model265 {
  const Model265({required this.id, required this.value});

  final int id;
  final String value;

  factory Model265.fromJson(Map<String, dynamic> json) =>
      _$Model265FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model265ToJson(this);
}
