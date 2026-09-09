import 'package:json_annotation/json_annotation.dart';

part 'model_225.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model225 {
  const Model225({required this.id, required this.value});

  final int id;
  final String value;

  factory Model225.fromJson(Map<String, dynamic> json) =>
      _$Model225FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model225ToJson(this);
}
