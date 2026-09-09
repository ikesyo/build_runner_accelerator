import 'package:json_annotation/json_annotation.dart';

part 'model_129.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model129 {
  const Model129({required this.id, required this.value});

  final int id;
  final String value;

  factory Model129.fromJson(Map<String, dynamic> json) =>
      _$Model129FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model129ToJson(this);
}
