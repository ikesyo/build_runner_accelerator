import 'package:json_annotation/json_annotation.dart';

part 'model_290.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model290 {
  const Model290({required this.id, required this.value});

  final int id;
  final String value;

  factory Model290.fromJson(Map<String, dynamic> json) =>
      _$Model290FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model290ToJson(this);
}
