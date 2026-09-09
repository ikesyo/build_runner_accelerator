import 'package:json_annotation/json_annotation.dart';

part 'model_104.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model104 {
  const Model104({required this.id, required this.value});

  final int id;
  final String value;

  factory Model104.fromJson(Map<String, dynamic> json) =>
      _$Model104FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model104ToJson(this);
}
