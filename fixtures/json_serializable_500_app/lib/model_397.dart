import 'package:json_annotation/json_annotation.dart';

part 'model_397.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model397 {
  const Model397({required this.id, required this.value});

  final int id;
  final String value;

  factory Model397.fromJson(Map<String, dynamic> json) =>
      _$Model397FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model397ToJson(this);
}
