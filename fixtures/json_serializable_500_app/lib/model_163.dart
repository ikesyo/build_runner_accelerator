import 'package:json_annotation/json_annotation.dart';

part 'model_163.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model163 {
  const Model163({required this.id, required this.value});

  final int id;
  final String value;

  factory Model163.fromJson(Map<String, dynamic> json) =>
      _$Model163FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model163ToJson(this);
}
